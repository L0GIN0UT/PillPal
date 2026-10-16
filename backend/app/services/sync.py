"""Offline-first sync push (TZ §4.3). Pull lives in ``app.services.sync_pull``.

Push applies a batch of mutations, each in its own SAVEPOINT so one bad
mutation never fails the others. The whole batch holds the journal lock of every
owner it touches (``app.services.scopes``, ``app.services.changes``), so pulls
never skip a change.

Each mutation is authorized before anything else: its target is loaded without an
access filter, the caller's role on its profile is looked up and
``app.domain.write_access`` returns a verdict (ADR 0006 §6). Only then do the
conflict rules below run, so a relative's write can never reach last-write-wins
for an entity they may not touch, and every ``current`` in a result goes through
the privacy projection.

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
from app.domain.write_access import check_write
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
from app.services.dose_events import record_dose_event
from app.services.rules import canonical_rule
from app.services.scopes import lock_batch_owners
from app.services.sync_state import entity_state, project_state
from app.services.sync_targets import Target, TargetResolver
from app.validators import MAX_FUTURE_SKEW

_log = get_logger("pillpal.sync")

Status = Literal["applied", "ignored_stale", "rejected"]
SyncRow = Profile | Medication | Schedule
Handler = Callable[[Mutation, svc.WriteContext], Awaitable["Outcome"]]

# Rejection codes this module raises (the rest come from validation and the services).
NOT_FOUND = "not_found"  # an entity the caller cannot see (or sees only redacted)
FORBIDDEN = "forbidden"
READ_ONLY = "read_only"
FORBIDDEN_FIELD = "forbidden_field"
PARENT_NOT_FOUND = "parent_not_found"  # a parent that is missing or foreign: indistinguishable
PARENT_DELETED = "parent_deleted"


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


def _projected(entity: str, row: Any, target: Target) -> EntityState | None:
    """``row`` as the caller may see it: every ``current`` in a result goes through here."""
    assert target.role is not None  # noqa: S101 - callers pass the access gate first
    return project_state(entity, entity_state(entity, row), target.role, target.medication_privacy)


class SyncService:
    def __init__(self, session: AsyncSession, user_id: uuid.UUID, device_id: str) -> None:
        self.session = session
        self.user_id = user_id
        self.device_id = device_id
        self.targets = TargetResolver(session, user_id)

    async def push(self, mutations: Sequence[Mutation]) -> list[MutationResult]:
        await lock_batch_owners(self.session, self.user_id, mutations)
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
            code = PARENT_NOT_FOUND if exc.code == "not_found" else exc.code
            return Outcome("rejected", code=code)
        except IntegrityError:  # pragma: no cover - defensive: the schemas mirror the CHECKs
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

    # -- authorization (before any conflict rule) ---------------------------------------

    def _gate(self, m: Mutation, t: Target, incoming_privacy: str | None = None) -> Outcome | None:
        """``None`` when the write may proceed, else the outcome that ends it."""
        verdict = check_write(
            t.role,
            m.entity,
            m.op,
            exists=t.row is not None,
            medication_privacy=t.medication_privacy,
            incoming_privacy=incoming_privacy,
        )
        if verdict == "allowed":
            return None
        if verdict == "noop":
            return Outcome("applied")  # nothing the caller can see: never reveals foreign rows
        child = m.entity in ("schedule", "dose_event")
        if t.row is None and (t.role is None or (child and verdict == NOT_FOUND)):
            # A create under a parent the caller cannot use: a missing, a foreign and a hidden
            # parent all answer alike.
            raise Rejected(PARENT_NOT_FOUND)
        if verdict == NOT_FOUND:
            return Outcome("rejected", code=NOT_FOUND)  # nothing is revealed, not even `current`
        current = _projected(m.entity, t.row, t) if t.row is not None else None
        return Outcome("rejected", code=verdict, current=current)

    # -- conflict rules ----------------------------------------------

    def _precheck_update(
        self, m: Mutation, row: SyncRow, same_payload: bool, t: Target
    ) -> Outcome | None:
        """Outcome when an upsert must not be applied to an existing row."""
        if row.deleted_at is not None:
            return Outcome("ignored_stale", row.version, "deleted", _projected(m.entity, row, t))
        order = _lww((m.client_updated_at, self.device_id), row)
        if order < 0:
            return Outcome("ignored_stale", row.version, current=_projected(m.entity, row, t))
        if order == 0:
            if same_payload:  # replay of a stored write: idempotent success
                return Outcome("applied", row.version)
            return Outcome("rejected", row.version, "key_conflict", _projected(m.entity, row, t))
        return None

    @staticmethod
    def _require_live(parent: Profile | Medication | None) -> None:
        if parent is None:  # pragma: no cover - the gate rejects a missing parent first
            raise Rejected(PARENT_NOT_FOUND)
        if parent.deleted_at is not None:
            raise Rejected(PARENT_DELETED)

    async def _delete(
        self,
        t: Target,
        ctx: svc.WriteContext,
        delete: Callable[..., Awaitable[None]],
        *args: Any,
    ) -> Outcome:
        """Deletes always win: no timestamp comparison, repeats are no-ops."""
        row = t.row
        if row.deleted_at is None:
            await delete(self.session, ctx, row, *args)
        return Outcome("applied", row.version)

    # -- profiles ----------------------------------------------------

    async def _upsert_profile(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = ProfileData.model_validate(_data(m))
        t = await self.targets.profile(m.id)
        if (denied := self._gate(m, t)) is not None:
            return denied
        row = t.row
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
        if (early := self._precheck_update(m, row, same, t)) is not None:
            return early
        if data.kind != row.kind:
            raise Rejected("immutable_field")
        await svc.update_profile(self.session, ctx, row, changes)
        return Outcome("applied", row.version)

    async def _delete_profile(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        t = await self.targets.profile(m.id)
        if (denied := self._gate(m, t)) is not None:
            return denied
        return await self._delete(t, ctx, svc.delete_profile)

    # -- medications -------------------------------------------------

    async def _upsert_medication(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = MedicationData.model_validate(_data(m))
        fields = data.model_dump(include=set(MedicationFields.model_fields))
        t = await self.targets.medication(m.id, data.profile_id)
        if (denied := self._gate(m, t, data.privacy)) is not None:
            return denied
        row = t.row
        if row is None:
            self._require_live(t.profile)
            row = await svc.create_medication(
                self.session, ctx, medication_id=m.id, profile_id=data.profile_id, fields=fields
            )
            return Outcome("applied", row.version)
        same = row.profile_id == data.profile_id and all(
            getattr(row, key) == value for key, value in fields.items()
        )
        if (early := self._precheck_update(m, row, same, t)) is not None:
            return early
        if data.profile_id != row.profile_id:
            raise Rejected("immutable_field")
        await svc.update_medication(self.session, ctx, row, fields)
        return Outcome("applied", row.version)

    async def _delete_medication(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        t = await self.targets.medication(m.id, None)
        if (denied := self._gate(m, t)) is not None:
            return denied
        return await self._delete(t, ctx, svc.delete_medication)

    # -- schedules ---------------------------------------------------

    async def _upsert_schedule(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = ScheduleData.model_validate(_data(m))
        rule = canonical_rule(data.rule)
        t = await self.targets.schedule(m.id, data.medication_id)
        if (denied := self._gate(m, t)) is not None:
            return denied
        row = t.row
        if row is None:
            self._require_live(t.parent)
            assert t.profile is not None  # noqa: S101 - the gate passed: the parent resolved
            row = await svc.create_schedule(
                self.session,
                ctx,
                schedule_id=m.id,
                profile_id=t.profile.id,
                medication_id=data.medication_id,
                rule=rule,
            )
            return Outcome("applied", row.version)
        same = (row.medication_id, row.rule) == (data.medication_id, rule)
        if (early := self._precheck_update(m, row, same, t)) is not None:
            return early
        if data.medication_id != row.medication_id:
            raise Rejected("immutable_field")
        assert t.profile is not None  # noqa: S101
        await svc.update_schedule(self.session, ctx, row, t.profile.id, rule)
        return Outcome("applied", row.version)

    async def _delete_schedule(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        t = await self.targets.schedule(m.id, None)
        if (denied := self._gate(m, t)) is not None:
            return denied
        assert t.profile is not None  # noqa: S101
        return await self._delete(t, ctx, svc.delete_schedule, t.profile.id)

    # -- dose events -------------------------------------------------

    async def _append_dose_event(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = DoseEventData.model_validate(_data(m))
        t = await self.targets.dose_event(m.id, data.medication_id)
        if (denied := self._gate(m, t)) is not None:
            return denied
        await record_dose_event(self.session, self.user_id, self.device_id, m.id, data)
        return Outcome("applied")

    async def _reject_append_only(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        raise Rejected("append_only")
