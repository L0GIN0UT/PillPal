"""Offline-first sync (TZ §4.3).

Push: a batch of mutations, each applied in its own SAVEPOINT so one bad
mutation never fails the others. Mutable entities use last-write-wins on
``(client_updated_at, device_id)``; tombstones are terminal (an upsert never
resurrects a deleted id - clients create new ids instead). Dose events are an
idempotent append. Every applied change is journaled in ``sync_changes``.

Pull: journal entries after a cursor, each carrying the entity's *current*
state (or a tombstone), deduplicated per page.
"""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable, Sequence
from datetime import datetime
from typing import Any, Literal

from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import DoseEvent, Medication, Profile, Schedule, SyncChange
from app.errors import AppError
from app.observability import get_logger
from app.schemas.entities import (
    Change,
    DoseEventData,
    DoseEventOut,
    MedicationData,
    MedicationFields,
    MedicationOut,
    Mutation,
    MutationResult,
    ProfileData,
    ProfileOut,
    PullResponse,
    ScheduleData,
    ScheduleOut,
)
from app.services import entities as svc
from app.services.auth import touch_device
from app.services.rules import canonical_rule
from app.validators import MAX_FUTURE_SKEW

_log = get_logger("pillpal.sync")

Status = Literal["applied", "ignored_stale", "rejected"]
SyncRow = Profile | Medication | Schedule


class Rejected(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class Outcome:
    def __init__(self, status: Status, version: int | None = None, code: str | None = None):
        self.status = status
        self.version = version
        self.code = code


def _lww(incoming: tuple[datetime, str], row: SyncRow) -> int:
    """Compare LWW keys: >0 incoming newer, 0 same write, <0 incoming older."""
    current = (row.client_updated_at, row.updated_by_device)
    return (incoming > current) - (incoming < current)


class SyncService:
    def __init__(self, session: AsyncSession, user_id: uuid.UUID, device_id: str) -> None:
        self.session = session
        self.user_id = user_id
        self.device_id = device_id

    # -- push ----------------------------------------------------------------

    async def push(self, mutations: Sequence[Mutation]) -> list[MutationResult]:
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
        handlers: dict[tuple[str, str], Callable[[Mutation, svc.WriteContext], Awaitable[Outcome]]]
        handlers = {
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

    def _key(self, m: Mutation) -> tuple[datetime, str]:
        return (m.client_updated_at, self.device_id)

    def _precheck_update(self, m: Mutation, row: SyncRow) -> Outcome | None:
        """Outcome when an upsert must not be applied to an existing row."""
        if row.deleted_at is not None:
            return Outcome("ignored_stale", row.version, code="deleted")
        order = _lww(self._key(m), row)
        if order < 0:
            return Outcome("ignored_stale", row.version)
        if order == 0:
            # Replay of a write that is already stored: idempotent success.
            return Outcome("applied", row.version)
        return None

    def _precheck_delete(self, m: Mutation, row: SyncRow) -> Outcome | None:
        if row.deleted_at is not None:
            return Outcome("applied", row.version)
        if _lww(self._key(m), row) < 0:
            return Outcome("ignored_stale", row.version)
        return None

    # profiles

    async def _upsert_profile(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = ProfileData.model_validate(m.data)
        row = await svc.load_profile(
            self.session, self.user_id, m.id, include_deleted=True, lock=True
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
            )
            return Outcome("applied", row.version)
        if (early := self._precheck_update(m, row)) is not None:
            return early
        if data.kind != row.kind:
            raise Rejected("immutable_field")
        await svc.update_profile(
            self.session,
            ctx,
            row,
            {"display_name": data.display_name, "timezone": data.timezone},
        )
        return Outcome("applied", row.version)

    async def _delete_profile(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        row = await svc.load_profile(
            self.session, self.user_id, m.id, include_deleted=True, lock=True
        )
        if row is None:
            return Outcome("applied")  # never seen on the server: nothing to delete
        if (early := self._precheck_delete(m, row)) is not None:
            return early
        await svc.delete_profile(self.session, ctx, row)
        return Outcome("applied", row.version)

    # medications

    async def _upsert_medication(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = MedicationData.model_validate(m.data)
        fields = data.model_dump(include=set(MedicationFields.model_fields))
        row = await svc.load_medication(
            self.session, self.user_id, m.id, include_deleted=True, lock=True
        )
        if row is None:
            if await svc.load_profile(self.session, self.user_id, data.profile_id) is None:
                raise Rejected("parent_not_found")
            row = await svc.create_medication(
                self.session, ctx, medication_id=m.id, profile_id=data.profile_id, fields=fields
            )
            return Outcome("applied", row.version)
        if (early := self._precheck_update(m, row)) is not None:
            return early
        if data.profile_id != row.profile_id:
            raise Rejected("immutable_field")
        await svc.update_medication(self.session, ctx, row, fields)
        return Outcome("applied", row.version)

    async def _delete_medication(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        row = await svc.load_medication(
            self.session, self.user_id, m.id, include_deleted=True, lock=True
        )
        if row is None:
            return Outcome("applied")  # never seen on the server: nothing to delete
        if (early := self._precheck_delete(m, row)) is not None:
            return early
        await svc.delete_medication(self.session, ctx, row)
        return Outcome("applied", row.version)

    # schedules

    async def _upsert_schedule(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = ScheduleData.model_validate(m.data)
        rule = canonical_rule(data.rule)
        row = await svc.load_schedule(
            self.session, self.user_id, m.id, include_deleted=True, lock=True
        )
        if row is None:
            if await svc.load_medication(self.session, self.user_id, data.medication_id) is None:
                raise Rejected("parent_not_found")
            row = await svc.create_schedule(
                self.session, ctx, schedule_id=m.id, medication_id=data.medication_id, rule=rule
            )
            return Outcome("applied", row.version)
        if (early := self._precheck_update(m, row)) is not None:
            return early
        if data.medication_id != row.medication_id:
            raise Rejected("immutable_field")
        await svc.update_schedule(self.session, ctx, row, rule)
        return Outcome("applied", row.version)

    async def _delete_schedule(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        row = await svc.load_schedule(
            self.session, self.user_id, m.id, include_deleted=True, lock=True
        )
        if row is None:
            return Outcome("applied")  # never seen on the server: nothing to delete
        if (early := self._precheck_delete(m, row)) is not None:
            return early
        await svc.delete_schedule(self.session, ctx, row)
        return Outcome("applied", row.version)

    # dose events

    async def _append_dose_event(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        data = DoseEventData.model_validate(m.data)
        await svc.record_dose_event(self.session, self.user_id, self.device_id, m.id, data)
        return Outcome("applied")

    async def _reject_append_only(self, m: Mutation, ctx: svc.WriteContext) -> Outcome:
        raise Rejected("append_only")

    # -- pull ----------------------------------------------------------------

    async def pull(self, cursor: int, limit: int) -> PullResponse:
        rows = (
            await self.session.execute(
                select(SyncChange.seq, SyncChange.entity, SyncChange.entity_id)
                .where(SyncChange.user_id == self.user_id, SyncChange.seq > cursor)
                .order_by(SyncChange.seq)
                .limit(limit + 1)
            )
        ).all()
        has_more = len(rows) > limit
        page = rows[:limit]
        if not page:
            return PullResponse(changes=[], next_cursor=cursor, has_more=False)

        # Several changes of one entity in a page collapse into the latest one:
        # each carries the current state anyway.
        latest: dict[tuple[str, uuid.UUID], int] = {}
        for seq, entity, entity_id in page:
            latest[(entity, entity_id)] = seq
        states = await self._current_states(list(latest))

        changes: list[Change] = []
        for (entity, entity_id), seq in sorted(latest.items(), key=lambda kv: kv[1]):
            state = states.get((entity, entity_id))
            if state is None:  # pragma: no cover - journal rows always have an entity
                continue
            deleted, data = state
            changes.append(
                Change(
                    seq=seq,
                    entity=entity,
                    id=entity_id,
                    op="delete" if deleted else "upsert",
                    data=None if deleted else data,
                )
            )
        return PullResponse(changes=changes, next_cursor=page[-1][0], has_more=has_more)

    async def _current_states(
        self, keys: list[tuple[str, uuid.UUID]]
    ) -> dict[tuple[str, uuid.UUID], tuple[bool, dict[str, Any]]]:
        by_entity: dict[str, list[uuid.UUID]] = {}
        for entity, entity_id in keys:
            by_entity.setdefault(entity, []).append(entity_id)
        out: dict[tuple[str, uuid.UUID], tuple[bool, dict[str, Any]]] = {}
        owner = Profile.owner_user_id == self.user_id

        if ids := by_entity.get("profile"):
            for p in await self.session.scalars(select(Profile).where(Profile.id.in_(ids), owner)):
                out[("profile", p.id)] = (
                    p.deleted_at is not None,
                    ProfileOut.model_validate(p).model_dump(mode="json"),
                )
        if ids := by_entity.get("medication"):
            for med in await self.session.scalars(
                select(Medication)
                .join(Profile, Profile.id == Medication.profile_id)
                .where(Medication.id.in_(ids), owner)
            ):
                out[("medication", med.id)] = (
                    med.deleted_at is not None,
                    MedicationOut.model_validate(med).model_dump(mode="json"),
                )
        if ids := by_entity.get("schedule"):
            for s in await self.session.scalars(
                select(Schedule)
                .join(Medication, Medication.id == Schedule.medication_id)
                .join(Profile, Profile.id == Medication.profile_id)
                .where(Schedule.id.in_(ids), owner)
            ):
                out[("schedule", s.id)] = (
                    s.deleted_at is not None,
                    ScheduleOut.model_validate(s).model_dump(mode="json"),
                )
        if ids := by_entity.get("dose_event"):
            for e in await self.session.scalars(
                select(DoseEvent)
                .join(Profile, Profile.id == DoseEvent.profile_id)
                .where(DoseEvent.id.in_(ids), owner)
            ):
                out[("dose_event", e.id)] = (
                    False,
                    DoseEventOut.model_validate(e).model_dump(mode="json"),
                )
        return out
