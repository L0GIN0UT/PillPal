"""``promo create``, ``promo list`` and ``promo disable`` (ADR 0018 section 5).

Create runs in one transaction and returns the codes only after the commit, so a failed batch
prints nothing. The codes exist in plain text here and in the caller's output only; the database
holds their keyed digests, and the audit row holds the id of the code.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.promo import PromoCode
from app.domain.promo import code_digest, generate_code, group_code
from app.services.admin_audit import Operator, record_audit


class PromoNotFound(Exception):
    """No promo code with this id."""


@dataclass(frozen=True)
class NewCampaign:
    label: str
    kind: str
    max_activations: int
    grant_days: int | None
    expires_at: datetime | None


@dataclass(frozen=True)
class PromoSummary:
    id: uuid.UUID
    label: str
    kind: str
    grant_days: int | None
    activations: int
    max_activations: int
    expires_at: datetime | None
    state: str


def state_of(row: PromoCode, now: datetime) -> str:
    if row.disabled_at is not None:
        return "disabled"
    if row.expires_at is not None and row.expires_at <= now:
        return "expired"
    if row.activations >= row.max_activations:
        return "exhausted"
    return "active"


async def create_codes(
    maker: async_sessionmaker[AsyncSession],
    *,
    key: bytes,
    length: int,
    count: int,
    campaign: NewCampaign,
    operator: Operator,
    now: datetime,
) -> list[tuple[uuid.UUID, str]]:
    promo_codes: list[tuple[uuid.UUID, str]] = []  # (id, grouped code): shown once
    async with maker() as session, session.begin():
        for _ in range(count):
            promo_code = generate_code(length)
            code_id = uuid.uuid4()
            session.add(
                PromoCode(
                    id=code_id,
                    code_digest=code_digest(key, promo_code),
                    label=campaign.label,
                    kind=campaign.kind,
                    grant_days=campaign.grant_days,
                    max_activations=campaign.max_activations,
                    expires_at=campaign.expires_at,
                    created_at=now,
                )
            )
            record_audit(
                session,
                operator,
                action="promo_create",
                at=now,
                object_id=code_id,
                kind=campaign.kind,
            )
            promo_codes.append((code_id, group_code(promo_code)))
    return promo_codes


async def list_codes(
    maker: async_sessionmaker[AsyncSession], *, limit: int, now: datetime
) -> list[PromoSummary]:
    async with maker() as session:
        rows = await session.scalars(
            select(PromoCode).order_by(PromoCode.created_at.desc(), PromoCode.id).limit(limit)
        )
        return [
            PromoSummary(
                id=row.id,
                label=row.label,
                kind=row.kind,
                grant_days=row.grant_days,
                activations=row.activations,
                max_activations=row.max_activations,
                expires_at=row.expires_at,
                state=state_of(row, now),
            )
            for row in rows
        ]


async def disable_code(
    maker: async_sessionmaker[AsyncSession],
    *,
    code_id: uuid.UUID,
    operator: Operator,
    now: datetime,
) -> bool:
    """Disable the code; ``False`` when it already was (no second audit row)."""
    async with maker() as session, session.begin():
        row = await session.scalar(
            select(PromoCode).where(PromoCode.id == code_id).with_for_update()
        )
        if row is None:
            raise PromoNotFound
        if row.disabled_at is not None:
            return False
        row.disabled_at = now
        record_audit(
            session, operator, action="promo_disable", at=now, object_id=code_id, kind=row.kind
        )
        return True
