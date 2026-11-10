"""``entitlement grant`` and ``entitlement revoke`` (ADR 0018 section 5).

Each runs in one transaction under the account's row lock, which also serialises it with the
erase job. An unknown account, or a pending-deletion one for a grant, is one error
(``AccountNotFound``): the CLI has no HTTP surface, so nothing is enumerable.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import ColumnElement, or_, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.db.entitlements import Entitlement
from app.db.models import User
from app.services.admin_audit import Operator, record_audit

SOURCE = "admin_grant"


class AccountNotFound(Exception):
    """No such account, or it is waiting for its deletion."""


@dataclass(frozen=True)
class GrantResult:
    account_id: uuid.UUID
    entitlement_id: uuid.UUID
    created: bool


@dataclass(frozen=True)
class RevokeResult:
    account_id: uuid.UUID
    revoked: int


async def _lock_account(
    session: AsyncSession, *where: ColumnElement[bool], allow_pending: bool = False
) -> User:
    stmt = select(User).where(*where)
    if not allow_pending:
        stmt = stmt.where(User.deletion_requested_at.is_(None))
    user = await session.scalar(stmt.with_for_update())
    if user is None:
        raise AccountNotFound
    return user


def _same_expiry(expires_at: datetime | None) -> ColumnElement[bool]:
    if expires_at is None:
        return Entitlement.expires_at.is_(None)
    return Entitlement.expires_at == expires_at


async def grant_entitlement(
    maker: async_sessionmaker[AsyncSession],
    *,
    email: str,
    kind: str,
    expires_at: datetime | None,
    operator: Operator,
    now: datetime,
) -> GrantResult:
    """Grant ``kind`` to the account with this e-mail; a replay of the same grant is a no-op.

    ``email`` is already normalised (``app.schemas.auth.normalize_email``). Idempotency relies on
    the user row lock taken below: the check and the insert are serialised per account. The
    promo-redeem (5.4) and purchase (5.10) grant paths must take the same lock.
    """
    async with maker() as session, session.begin():
        user = await _lock_account(session, User.email == email)
        existing = await session.scalar(
            select(Entitlement.id).where(
                Entitlement.user_id == user.id,
                Entitlement.kind == kind,
                Entitlement.source == SOURCE,
                Entitlement.revoked_at.is_(None),
                _same_expiry(expires_at),
                or_(Entitlement.expires_at.is_(None), Entitlement.expires_at > now),
            )
        )
        if existing is not None:
            return GrantResult(user.id, existing, created=False)
        entitlement_id = uuid.uuid4()
        session.add(
            Entitlement(
                id=entitlement_id,
                user_id=user.id,
                kind=kind,
                source=SOURCE,
                granted_at=now,
                expires_at=expires_at,
            )
        )
        record_audit(
            session,
            operator,
            action="entitlement_grant",
            at=now,
            target_user_id=user.id,
            object_id=entitlement_id,
            kind=kind,
        )
        return GrantResult(user.id, entitlement_id, created=True)


async def revoke_entitlements(
    maker: async_sessionmaker[AsyncSession],
    *,
    account_id: uuid.UUID,
    kind: str,
    operator: Operator,
    now: datetime,
) -> RevokeResult:
    """Revoke every entitlement of ``kind`` in force for the account, whatever its source."""
    async with maker() as session, session.begin():
        # A pending-deletion account may be revoked (harmless); only a grant is refused.
        user = await _lock_account(session, User.id == account_id, allow_pending=True)
        rows = (
            await session.scalars(
                select(Entitlement)
                .where(
                    Entitlement.user_id == user.id,
                    Entitlement.kind == kind,
                    Entitlement.revoked_at.is_(None),
                    or_(Entitlement.expires_at.is_(None), Entitlement.expires_at > now),
                )
                .order_by(Entitlement.granted_at, Entitlement.id)
                .with_for_update()
            )
        ).all()
        for row in rows:
            row.revoked_at = now
            record_audit(
                session,
                operator,
                action="entitlement_revoke",
                at=now,
                target_user_id=user.id,
                object_id=row.id,
                kind=kind,
            )
        return RevokeResult(user.id, len(rows))
