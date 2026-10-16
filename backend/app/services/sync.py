"""Offline-first sync push (TZ §4.3). Pull lives in ``app.services.sync_pull``.

Push applies a batch of mutations, each in its own SAVEPOINT so one bad
mutation never fails the others. The whole batch holds the per-user journal
lock (``app.services.changes``), so pulls never skip a change.

Conflict rules, chosen so every device converges whatever the arrival order:

* upserts of mutable entities use last-write-wins on the key
  ``(client_updated_at, device_id)``; an older write is ``ignored_stale`` and
  the result carries the server state to adopt. The same key with a different
  payload is ``rejected/key_conflict`` (a client bug: keys must be unique);
* deletes are final and always win, whatever their timestamp; tombstones are
  terminal (an upsert never resurrects a deleted id - clients use new ids);
  a delete never moves a conflict key backwards;
* a child cannot be created under a deleted parent (``parent_deleted``);
* dose events are an idempotent append.
"""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable, Sequence
from datetime import datetime
from typing import Any, Literal

from pydantic import ValidationError
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import Medication, Profile, Schedule
from app.errors import AppError
from app.observability import get_logger
from app.schemas.entities import (
    DoseEventData,
    EntityState,
    MedicationData,
    MedicationFields,
    Mutation,
    MutationResult,
    ProfileData,
    ScheduleData,
    strip_server_fields,
)
from app.services import entities as svc
from app.services.auth import touch_device
from app.services.changes import lock_journal
from app.services.dose_events import record_dose_event
from app.services.rules import canonical_rule
from app.services.sync_pull import entity_state
from app.validators import MAX_FUTURE_SKEW

_log = get_logger("pillpal.sync")

Status = Literal["applied", "ignored_stale", "rejected"]
SyncRow = Profile | Medication | Schedule
Handler = Callable[[Mutation, svc.WriteContext], Awaitable["Outcome"]]


class Rejected(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class Outcome:
    def __init__(
        self,
        status: Status,
        version: int | None = None,
        code: str | None = None,
        current: EntityState | None = None,
    ) -> None:
        self.status = status
        self.version = version
        self.code = code
        self.current = current


def _lww(incoming: tuple[datetime, str], row: SyncRow) -> int:
    """Compare LWW keys: >0 incoming newer, 0 same key, <0 incoming older."""
    current = (row.client_updated_at, row.updated_by_device)
    return (incoming > current) - (incoming < current)


def _data(m: Mutation) -> dict[str, Any] | None:
    return strip_server_fields(m.entity, m.data)


class SyncService:
    def __init__(self, session: AsyncSession, user_id: uuid.UUID, device_id: str) -> None:
        self.session = session
        self.user_id = user_id
        self.device_id = device_id

    async def push(self, mutations: Sequence[Mutation]) -> list[MutationResult]:
        await lock_journal(self.session, self.user_id)
        await touch_device(self.session, self.user_id, self.device_id)
        results: list[MutationResult] = []
        counts: dict[str, int] = {"applied": 0, "ignored_stale": 0, "rejected": 0}
        for m in mutations:
            outcome = await self._apply_isolated(m)
            counts[outcome.status] += 1
            results.append(
                MutationResult(
                    entity=m.entity,
                    id=m.id,
                    status=outcome.status,
                    code=outcome.code,
                    version=outcome.version,
                    current=outcome.current,
                )
            )
        await self.session.commit()
        _log.info("sync_push", user_id=str(self.user_id), **counts)
        return results

    async def _apply_isolated(self, m: Mutation) -> Outcome:
        if m.client_updated_at > svc.utcnow() + MAX_FUTURE_SKEW:
            return Outcome("rejected", code="clock_skew")
        try:
            async with self.session.begin_nested():
                return await self._apply(m)
        except Rejected as exc:
            return Outcome("rejected", code=exc.code)
        except ValidationError:
            return Outcome("rejected", code="validation_error")
        except AppError as exc:
            # In a batch, a missing/foreign referenced entity is always a parent.
            code = "parent_not_found" if exc.code == "not_found" else exc.code
            return Outcome("rejected", code=code)
        except IntegrityError:
            return Outcome("rejected", code="integrity_error")

    async def _apply(self, m: Mutation) -> Outcome:
        handlers: dict[tuple[str, str], Handler] = {
            ("profile", "upsert"): self._upsert_profile,
            ("profile", "delete"): self._delete_profile,
            ("medication", "upsert"): self._upsert_medication,
            ("medication", "delete"): self._delete_medication,
            ("schedule", "upsert"): self._upsert_schedule,
            ("schedule", "delete"): self._delete_schedule,
            ("dose_event", "upsert"): self._append_dose_event,
            ("dose_event", "delete"): self._reject_append_only,
        }
        ctx = svc.WriteContext(self.user_id, self.device_id, m.client_updated_at)
        return await handlers[(m.entity, m.op)](m, ctx)

    # -- conflict rules ------------------------------------------------------

    def _precheck_update(self, m: Mutation, row: SyncRow, same_payload: bool) -> Outcome | None:
        """Outcome when an upsert must not be applied to an existing row."""
        if row.deleted_at is not None:
            return Outcome("ignored_stale", row.version, "deleted", entity_state(m.entity, row))
        order = _lww((m.client_updated_at, self.device_id), row)
        if order < 0:
            return Outcome("ignored_stale", row.version, current=entity_state(m.entity, row))
        if order == 0:
            if same_payload:  # replay of a stored write: idempotent success
                return Outcome("applied", row.version)
            return Outcome("rejected", row.version, "key_conflict", entity_state(m.entity, row))
        return None

    async def _require_live_parent(
        self, load: Callable[..., Awaitable[SyncRow | None]], parent_id: uuid.UUID
    ) -> None:
        # FOR SHARE: a concurrent delete of the parent waits for this insert
        # (and then tombstones the new child too) instead of racing past it.
        parent = await load(
            self.session, self.user_id, parent_id, include_deleted=True, lock="share"
        )
        if parent is None:
            raise Rejected("parent_not_found")
        if parent.deleted_at is not None:
            raise Rejected("parent_deleted")

    async def _delete(
        self,
        m: Mutation,
        ctx: svc.WriteContext,
        load: Callable[..., Awaitable[Any]],
        delete: Callable[[AsyncSession, svc.WriteContext, Any], Awaitable[None]],
    ) -> Outcome:
        """Deletes always win: no timestamp comparison, repeats are no-ops."""
        row = await load(self.session, self.user_id, m.id, include_deleted=True, lock="update")
        if row is None:
            return Outcome("applied")  # never seen on the server: nothing to delete
        if row.deleted_at is None:
            await delete(self.session, ctx, row)
        return Outcome("applied", row.version)

    # -- profiles --------------------------------------------------------------

    async def _upsert_profile(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = ProfileData.model_validate(_data(m))
        row = await svc.load_profile(
            self.session, self.user_id, m.id, include_deleted=True, lock="update"
        )
        if row is None:
            if data.kind != "managed":
                raise Rejected("invalid_kind")
            row = await svc.create_profile(
                self.session,
                ctx,
                profile_id=m.id,
                display_name=data.display_name,
                timezone=data.timezone,
                missed_alert_minutes=data.missed_alert_minutes,
                missed_alerts_enabled=data.missed_alerts_enabled,
            )
            return Outcome("applied", row.version)
        changes = data.mutable_fields()
        same = row.kind == data.kind and all(getattr(row, k) == v for k, v in changes.items())
        if (early := self._precheck_update(m, row, same)) is not None:
            return early
        if data.kind != row.kind:
            raise Rejected("immutable_field")
        await svc.update_profile(self.session, ctx, row, changes)
        return Outcome("applied", row.version)

    async def _delete_profile(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        return await self._delete(m, ctx, svc.load_profile, svc.delete_profile)

    # -- medications -------------------------------------------------------------

    async def _upsert_medication(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = MedicationData.model_validate(_data(m))
        fields = data.model_dump(include=set(MedicationFields.model_fields))
        row = await svc.load_medication(
            self.session, self.user_id, m.id, include_deleted=True, lock="update"
        )
        if row is None:
            await self._require_live_parent(svc.load_profile, data.profile_id)
            row = await svc.create_medication(
                self.session, ctx, medication_id=m.id, profile_id=data.profile_id, fields=fields
            )
            return Outcome("applied", row.version)
        same = row.profile_id == data.profile_id and all(
            getattr(row, key) == value for key, value in fields.items()
        )
        if (early := self._precheck_update(m, row, same)) is not None:
            return early
        if data.profile_id != row.profile_id:
            raise Rejected("immutable_field")
        await svc.update_medication(self.session, ctx, row, fields)
        return Outcome("applied", row.version)

    async def _delete_medication(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        return await self._delete(m, ctx, svc.load_medication, svc.delete_medication)

    # -- schedules -----------------------------------------------------------------

    async def _upsert_schedule(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = ScheduleData.model_validate(_data(m))
        rule = canonical_rule(data.rule)
        row = await svc.load_schedule(
            self.session, self.user_id, m.id, include_deleted=True, lock="update"
        )
        if row is None:
            await self._require_live_parent(svc.load_medication, data.medication_id)
            row = await svc.create_schedule(
                self.session, ctx, schedule_id=m.id, medication_id=data.medication_id, rule=rule
            )
            return Outcome("applied", row.version)
        same = (row.medication_id, row.rule) == (data.medication_id, rule)
        if (early := self._precheck_update(m, row, same)) is not None:
            return early
        if data.medication_id != row.medication_id:
            raise Rejected("immutable_field")
        await svc.update_schedule(self.session, ctx, row, rule)
        return Outcome("applied", row.version)

    async def _delete_schedule(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        return await self._delete(m, ctx, svc.load_schedule, svc.delete_schedule)

    # -- dose events -------------------------------------------------------------------

    async def _append_dose_event(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = DoseEventData.model_validate(_data(m))
        await record_dose_event(self.session, self.user_id, self.device_id, m.id, data)
        return Outcome("applied")

    async def _reject_append_only(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        raise Rejected("append_only")
