"""Delivery of the push outbox: claim, re-check access, send, record (ADR 0008 §6).

One run of :func:`deliver_pending` loops over batches:

1. **Claim** (:func:`claim_batch`, one short transaction). ``SELECT ... FOR UPDATE SKIP
   LOCKED`` takes up to ``PUSH_BATCH_SIZE`` due rows, so concurrent workers never claim the
   same row, and the *same query* decides whether the recipient may still be told: access
   changes between enqueue and send (a revoked grant, a leave, a narrowing to ``hidden``, an
   archive, a deletion request), and a push that outlives it would disclose what the
   relative is no longer allowed to see. Rows that fail the check are ``dropped`` with
   ``access_changed`` and never reach a sender; stale rows and rows out of attempts are
   dropped too. The rest get ``attempts + 1`` and a *lease* (``next_attempt_at`` moves
   ``PUSH_CLAIM_LEASE_SECONDS`` ahead) and the transaction commits, so no database
   connection or row lock is held while talking to providers.
2. **Send** concurrently, bounded by ``PUSH_SEND_CONCURRENCY``.
3. **Record** (one transaction): ``OK`` -> ``sent``; ``INVALID_TOKEN`` -> the token is deleted
   (its other pending rows cascade), unless it was registered after the provider said it was
   dead; ``RETRY`` -> back-off (30 s, 2 min, 10 min, 30 min, or ``Retry-After`` when longer,
   capped at the staleness window), ``dropped`` after ``PUSH_MAX_ATTEMPTS``; ``FATAL`` ->
   ``dropped``. Only rows still ``pending`` are updated, so a concurrent cancel wins.

Delivery is at least once: a crash after sending but before recording makes the lease run out
and the row go out again, which devices collapse by notification id (APNs by collapse id).
Because the attempt is counted at claim time, a row that keeps crashing the worker is dropped
after ``PUSH_MAX_ATTEMPTS`` too.

Logs carry the delivery id, provider, outcome and error code; never a token, a payload or
exception text.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any

from pydantic import ValidationError
from redis.asyncio import Redis
from sqlalchemy import ColumnElement, Row, Select, and_, delete, exists, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from sqlalchemy.orm import aliased

from app.config import Settings
from app.db.models import Medication, Profile, User
from app.db.push import PushOutbox, PushToken
from app.db.relatives import ProfileGrant
from app.observability import get_logger
from app.push.base import Outcome, PushMessage, PushPayload, PushProvider, PushSender, SendResult
from app.redis_lock import try_lock
from app.services.access import grant_is_active
from app.services.push_outbox import ACCESS_CHANGED

_log = get_logger("pillpal.push")

STALE = "stale"
MAX_ATTEMPTS = "max_attempts"
SENDER_ERROR = "sender_error"
BAD_PAYLOAD = "bad_payload"
RUN_LOCK = "push_delivery"
TOKEN_REREGISTERED = "token_reregistered"  # noqa: S105 - an error code, not a secret


@dataclass(frozen=True)
class Claimed:
    id: int
    token_id: uuid.UUID
    provider: PushProvider
    token: str
    apns_environment: str | None
    payload: dict[str, Any]
    attempts: int  # including this attempt
    created_at: datetime


@dataclass(frozen=True)
class Claim:
    """What one claim decided: rows to send now, and rows dropped (reason -> count)."""

    items: list[Claimed]
    dropped: dict[str, int]

    @property
    def size(self) -> int:
        return len(self.items) + sum(self.dropped.values())


@dataclass
class DeliveryReport:
    claimed: int = 0
    sent: int = 0
    retried: int = 0
    dropped: int = 0
    invalid_tokens: int = 0
    failed: int = 0  # the job-runner protocol: a delivery run does not fail per row
    skipped_locked: bool = False  # another run held the lock
    dropped_by_reason: dict[str, int] = field(default_factory=dict)

    def drop(self, reason: str, count: int = 1) -> None:
        self.dropped += count
        self.dropped_by_reason[reason] = self.dropped_by_reason.get(reason, 0) + count


def _may_still_receive(recipient: Any, subject_owner: Any) -> ColumnElement[bool]:
    """Whether the recipient may still be told about the row's profile and medication.

    Same rules as the read paths (``app.services.access``): recipient and subject owner are
    not pending deletion, the profile is live and not archived, the recipient owns it or holds
    an *active* grant, and a ``hidden`` medication goes only to full-access roles (owner,
    guardian). A tombstoned medication is gone.
    """
    holds_grant = exists().where(
        ProfileGrant.profile_id == Profile.id,
        ProfileGrant.grantee_user_id == PushOutbox.recipient_user_id,
        grant_is_active(),
    )
    full_access = or_(
        Profile.owner_user_id == PushOutbox.recipient_user_id,
        exists().where(
            ProfileGrant.profile_id == Profile.id,
            ProfileGrant.grantee_user_id == PushOutbox.recipient_user_id,
            ProfileGrant.role == "guardian",
            grant_is_active(),
        ),
    )
    medication_ok = or_(
        PushOutbox.subject_medication_id.is_(None),
        and_(
            Medication.id.is_not(None),
            Medication.profile_id == Profile.id,
            Medication.deleted_at.is_(None),
            or_(Medication.privacy != "hidden", full_access),
        ),
    )
    return and_(
        recipient.deletion_requested_at.is_(None),
        Profile.id.is_not(None),
        Profile.deleted_at.is_(None),
        Profile.archived_at.is_(None),
        subject_owner.deletion_requested_at.is_(None),
        or_(Profile.owner_user_id == PushOutbox.recipient_user_id, holds_grant),
        medication_ok,
    )


def _due_rows(settings: Settings, now: datetime) -> Select[Any]:
    recipient, subject_owner = aliased(User), aliased(User)
    return (
        select(
            PushOutbox.id,
            PushOutbox.push_token_id,
            PushOutbox.payload,
            PushOutbox.attempts,
            PushOutbox.created_at,
            PushToken.provider,
            PushToken.token,
            PushToken.apns_environment,
            _may_still_receive(recipient, subject_owner).label("allowed"),
        )
        .join(PushToken, PushToken.id == PushOutbox.push_token_id)
        .join(recipient, recipient.id == PushOutbox.recipient_user_id)
        .outerjoin(Profile, Profile.id == PushOutbox.subject_profile_id)
        .outerjoin(subject_owner, subject_owner.id == Profile.owner_user_id)
        .outerjoin(Medication, Medication.id == PushOutbox.subject_medication_id)
        .where(PushOutbox.status == "pending", PushOutbox.next_attempt_at <= now)
        .order_by(PushOutbox.next_attempt_at, PushOutbox.id)
        .limit(settings.push_batch_size)
        .with_for_update(of=PushOutbox, skip_locked=True)
    )


def _classify(
    due: Sequence[Row[Any]], settings: Settings, now: datetime
) -> tuple[list[Claimed], dict[str, list[int]]]:
    """Split the locked rows into what to send and what to drop (reason -> row ids)."""
    stale_before = now - timedelta(seconds=settings.push_stale_after_seconds)
    claimed: list[Claimed] = []
    drops: dict[str, list[int]] = {}
    for row in due:
        if not row.allowed:
            drops.setdefault(ACCESS_CHANGED, []).append(row.id)
        elif row.created_at <= stale_before:
            drops.setdefault(STALE, []).append(row.id)
        elif row.attempts >= settings.push_max_attempts:
            drops.setdefault(MAX_ATTEMPTS, []).append(row.id)
        else:
            claimed.append(
                Claimed(
                    row.id,
                    row.push_token_id,
                    row.provider,
                    row.token,
                    row.apns_environment,
                    row.payload,
                    row.attempts + 1,
                    row.created_at,
                )
            )
    return claimed, drops


async def claim_batch(session: AsyncSession, settings: Settings, now: datetime) -> Claim:
    """Claim a batch (see the module docstring); commits. Rows that may not be sent are dropped."""
    due = (await session.execute(_due_rows(settings, now))).all()
    claimed, drops = _classify(due, settings, now)
    for reason, ids in drops.items():
        await session.execute(
            update(PushOutbox)
            .where(PushOutbox.id.in_(ids))
            .values(status="dropped", last_error_code=reason)
            .execution_options(synchronize_session=False)
        )
    if claimed:
        await session.execute(
            update(PushOutbox)
            .where(PushOutbox.id.in_([c.id for c in claimed]))
            .values(
                attempts=PushOutbox.attempts + 1,
                next_attempt_at=now + timedelta(seconds=settings.push_claim_lease_seconds),
            )
            .execution_options(synchronize_session=False)
        )
    await session.commit()
    for reason, ids in drops.items():
        _log.info("push_dropped", reason=reason, count=len(ids))
    return Claim(claimed, {reason: len(ids) for reason, ids in drops.items()})


def _message(settings: Settings, item: Claimed) -> PushMessage:
    return PushMessage(
        provider=item.provider,
        token=item.token,
        payload=PushPayload.model_validate(item.payload),
        delivery_id=str(item.id),
        apns_environment=item.apns_environment,  # type: ignore[arg-type]
        ttl_seconds=settings.push_stale_after_seconds,
    )


async def _send_one(
    sender: PushSender, settings: Settings, item: Claimed, gate: asyncio.Semaphore
) -> SendResult:
    async with gate:
        try:
            message = _message(settings, item)
        except ValidationError:
            # Cannot happen through ``enqueue``; a bad row must not take its batch down.
            return SendResult.fatal(BAD_PAYLOAD)
        try:
            return await sender.send(message)
        except Exception as exc:
            # A bug in a sender must not lose the batch: retry, and log the type only.
            _log.error(
                "push_sender_error",
                delivery_id=message.delivery_id,
                provider=message.provider,
                exc_type=type(exc).__name__,
            )
            return SendResult.retry(SENDER_ERROR)


def _retry_delay(settings: Settings, attempts: int, result: SendResult) -> timedelta:
    backoff = settings.push_retry_backoff_seconds
    delay = float(backoff[min(attempts - 1, len(backoff) - 1)])
    if result.retry_after_seconds is not None:
        delay = max(delay, min(result.retry_after_seconds, settings.push_stale_after_seconds))
    return timedelta(seconds=delay)


async def _delete_dead_token(session: AsyncSession, item: Claimed, result: SendResult) -> bool:
    """Delete the token the provider reports dead, unless it was registered after that instant.

    Matches the token *value* as well as the row: re-registering a device keeps the row id
    and replaces the token, and the fresh token must survive an answer about the old one.
    """
    stmt = delete(PushToken).where(
        PushToken.id == item.token_id,
        PushToken.token == item.token,
        PushToken.provider == item.provider,
    )
    if result.invalid_since is not None:
        stmt = stmt.where(PushToken.updated_at <= result.invalid_since)
    return (await session.execute(stmt.returning(PushToken.id))).first() is not None


def _unchanged_since_claim(item: Claimed) -> ColumnElement[bool]:
    """Fence: only the attempt that claimed the row may record its result.

    A lease that ran out lets a later run claim the row (``attempts`` goes up); the earlier,
    slow run's answer must then not overwrite the newer attempt's.
    """
    return and_(
        PushOutbox.id == item.id,
        PushOutbox.status == "pending",
        PushOutbox.attempts == item.attempts,
    )


async def _record(
    session: AsyncSession,
    settings: Settings,
    now: datetime,
    outcomes: list[tuple[Claimed, SendResult]],
    report: DeliveryReport,
) -> None:
    sent_tokens: list[uuid.UUID] = []
    for item, result in outcomes:
        code = result.code
        outcome = result.outcome
        if outcome is Outcome.INVALID_TOKEN:
            if await _delete_dead_token(session, item, result):
                report.invalid_tokens += 1
                continue
            # Registered again after the provider's answer: the token is alive.
            outcome, code = Outcome.RETRY, code or TOKEN_REREGISTERED
        fenced = _unchanged_since_claim(item)
        if outcome is Outcome.OK:
            values: dict[str, Any] = {"status": "sent", "sent_at": now, "last_error_code": None}
        elif outcome is Outcome.RETRY and item.attempts < settings.push_max_attempts:
            values = {
                "next_attempt_at": now + _retry_delay(settings, item.attempts, result),
                "last_error_code": code,
            }
        else:  # FATAL, or RETRY with no attempts left
            values = {"status": "dropped", "last_error_code": code or MAX_ATTEMPTS}
        applied = await session.execute(
            update(PushOutbox).where(fenced).values(**values).returning(PushOutbox.id)
        )
        if applied.first() is None:
            continue  # cancelled or claimed again meanwhile: the newer state wins
        if outcome is Outcome.OK:
            report.sent += 1
            sent_tokens.append(item.token_id)
        elif "status" in values:
            report.drop(values["last_error_code"])
        else:
            report.retried += 1
    if sent_tokens:
        await session.execute(
            update(PushToken).where(PushToken.id.in_(sent_tokens)).values(last_success_at=now)
        )
    await session.commit()


def _log_outcomes(outcomes: list[tuple[Claimed, SendResult]]) -> None:
    for item, result in outcomes:
        _log.log(
            20 if result.outcome is Outcome.OK else 30,
            "push_delivery",
            delivery_id=str(item.id),
            provider=item.provider,
            outcome=result.outcome.value,
            # Not ``code``: the log scrubber redacts that key (one-time e-mail codes).
            error_code=result.code,
            attempt=item.attempts,
        )


async def _deliver_batches(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    senders: Mapping[PushProvider, PushSender],
    now: Callable[[], datetime],
    report: DeliveryReport,
) -> None:
    gate = asyncio.Semaphore(settings.push_send_concurrency)
    for _ in range(settings.push_max_batches_per_run):
        async with maker() as session:
            claim = await claim_batch(session, settings, now())
        for reason, count in claim.dropped.items():
            report.drop(reason, count)
        report.claimed += len(claim.items)
        results = await asyncio.gather(
            *(_send_one(senders[item.provider], settings, item, gate) for item in claim.items)
        )
        outcomes = list(zip(claim.items, results, strict=True))
        _log_outcomes(outcomes)
        if outcomes:
            async with maker() as session:
                await _record(session, settings, now(), outcomes, report)
        if claim.size < settings.push_batch_size:
            break
    _log.info(
        "push_delivery_run",
        claimed=report.claimed,
        sent=report.sent,
        retried=report.retried,
        dropped=report.dropped,
        invalid_tokens=report.invalid_tokens,
    )


async def deliver_pending(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    senders: Mapping[PushProvider, PushSender],
    now: Callable[[], datetime],
    redis: Redis | None = None,
) -> DeliveryReport:
    """Deliver due rows in batches (at most ``PUSH_MAX_BATCHES_PER_RUN``); see the module doc.

    With ``redis``, one run at a time: a run that finds the lock held is skipped (the 10 s cron
    comes back), so a slow provider cannot make a second run re-claim rows whose lease ran out.
    """
    report = DeliveryReport()
    if redis is None:
        await _deliver_batches(maker, settings, senders, now, report)
        return report
    async with try_lock(redis, RUN_LOCK, settings.push_run_lock_seconds * 1000) as acquired:
        if not acquired:
            report.skipped_locked = True
            _log.info("push_delivery_skipped", reason="locked")
            return report
        await _deliver_batches(maker, settings, senders, now, report)
    return report
