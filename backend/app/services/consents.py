"""Consent records: what the account accepted, in which version (Phase 5.2a).

Health data, terms and privacy are withdrawn only by deleting the account (ADR 0010), so the
service has no withdrawal for them; the catalog contribution is recorded and withdrawn in
``consent_ledger`` (5.2b).
Consent texts and versions are not medical data, but nothing here is logged anyway except
opaque ids.
"""

from __future__ import annotations

import uuid
from collections.abc import Sequence
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.consents import Consent
from app.domain.consents import BASELINE_KINDS, CONSENT_KINDS, ConsentSource
from app.errors import AppError, unauthorized
from app.schemas.consents import ConsentIn
from app.services.account_deletion import lock_user


def known_versions(settings: Settings, kind: str) -> list[int]:
    return {
        "health_data": settings.consent_versions_health_data,
        "terms": settings.consent_versions_terms,
        "privacy": settings.consent_versions_privacy,
        "catalog_contribution": settings.gtin_link_consent_versions,
    }[kind]


def current_versions(settings: Settings) -> dict[str, int]:
    return {kind: known_versions(settings, kind)[-1] for kind in CONSENT_KINDS}


def required_kinds(settings: Settings) -> list[str]:
    """Kinds registration must carry; empty while ``CONSENT_REQUIRED_AT_REGISTRATION`` is off."""
    return list(BASELINE_KINDS) if settings.consent_required_at_registration else []


def unsupported_version() -> AppError:
    return AppError(422, "unsupported_consent_version", "This consent text version is unknown")


def unsupported_kind() -> AppError:
    return AppError(422, "unsupported_consent_kind", "This consent cannot be given here")


def consent_required() -> AppError:
    return AppError(422, "consent_required", "The current consents must be accepted")


def validate_registration_consents(
    settings: Settings, given: Sequence[ConsentIn] | None
) -> list[tuple[str, int]]:
    """The (kind, version) pairs to record, or a 422.

    Only the baseline kinds (health data, terms, privacy) are accepted; the catalog contribution
    is recorded where it is given (5.2b). The OAuth sign-up (5.6, source ``oauth_signup``) reuses
    this validator.

    Depends only on the request and the settings, never on whether the e-mail is known, so the
    answer cannot be used to find out which addresses have an account.
    """
    if given is None:
        if settings.consent_required_at_registration:
            raise consent_required()
        return []
    for item in given:
        if item.kind not in BASELINE_KINDS:
            raise unsupported_kind()
        if item.version not in known_versions(settings, item.kind):
            raise unsupported_version()
    accepted: dict[str, int] = {item.kind: item.version for item in given}
    current = current_versions(settings)
    if any(accepted.get(kind) != current[kind] for kind in BASELINE_KINDS):
        raise consent_required()
    return [(kind, accepted[kind]) for kind in BASELINE_KINDS]


def new_record(
    user_id: uuid.UUID, kind: str, version: int, source: ConsentSource, now: datetime
) -> Consent:
    return Consent(
        id=uuid.uuid4(),
        user_id=user_id,
        kind=kind,
        version=version,
        source=source,
        accepted_at=now,
    )


async def list_records(session: AsyncSession, user_id: uuid.UUID) -> list[Consent]:
    result = await session.scalars(
        select(Consent).where(Consent.user_id == user_id).order_by(Consent.accepted_at, Consent.id)
    )
    return list(result)


def missing_kinds(settings: Settings, records: Sequence[Consent]) -> list[str]:
    current = current_versions(settings)
    active = {(r.kind, r.version) for r in records if r.withdrawn_at is None}
    return [kind for kind in BASELINE_KINDS if (kind, current[kind]) not in active]


async def accept(
    session: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    item: ConsentIn,
    now: datetime,
) -> tuple[Consent, bool]:
    """Record an in-app acceptance of the current text; ``(row, created)``.

    The catalog contribution is recorded where it is given, on a medication link (5.2b), never
    from here. A replay of an active record returns it unchanged.
    """
    if item.kind not in BASELINE_KINDS:
        raise unsupported_kind()
    if item.version != current_versions(settings)[item.kind]:
        raise unsupported_version()
    # The user row lock serializes this with erasure, deletion requests and itself: no row is
    # added to a vanishing account and a concurrent replay finds the first one. The partial
    # unique index stays as the last line of defence.
    user = await lock_user(session, user_id)
    if user is None or user.pending_deletion:
        raise unauthorized()
    existing = await session.scalar(
        select(Consent).where(
            Consent.user_id == user_id,
            Consent.kind == item.kind,
            Consent.version == item.version,
            Consent.withdrawn_at.is_(None),
        )
    )
    if existing is not None:
        # Nothing changed: end the transaction (and the user lock). Detached first, because a
        # rollback would expire the row and the response is built from it afterwards.
        session.expunge(existing)
        await session.rollback()
        return existing, False
    row = new_record(user_id, item.kind, item.version, "in_app", now)
    session.add(row)
    await session.commit()
    return row, True
