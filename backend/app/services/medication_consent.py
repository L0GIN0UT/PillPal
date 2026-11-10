"""Applies the contribution-consent rule (``app.domain.link_consent``) to a medication write.

Sync push and REST both go through :func:`with_consent`, so a re-link resets the consent
whichever way it arrives, in the same versioned update (the owner's other devices get the
reset in their next pull). ``ConsentError`` becomes a stable 422.

:func:`reset_consent_in_profiles` is the same reset for medications whose profile changes hands.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from datetime import datetime
from typing import Any

from sqlalchemy import func, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings
from app.db.models import Medication
from app.domain.link_consent import ConsentError, ConsentRequest, LinkState, resolve_consent
from app.errors import AppError
from app.services.changes import record_changes

_MESSAGES = {
    "unsupported_consent_version": "This consent text version is not supported",
    "gtin_not_shareable": "This GTIN cannot be shared with the catalog",
    "contributions_disabled": "Contributing links to the catalog is not enabled",
    "forbidden_field": "Only the owner of the profile can share a link with the catalog",
    "gtin_link_needs_gtin_and_product": "Sharing a link needs both a GTIN and a catalog product",
}


def _state_of(row: Medication | None) -> LinkState:
    if row is None:
        return LinkState(None, None, False, None, None)
    return LinkState(
        row.gtin,
        row.catalog_product_id,
        row.gtin_link_shared,
        row.gtin_link_consent_version,
        row.gtin_link_consented_at,
    )


def with_consent(
    row: Medication | None,
    fields: dict[str, Any],
    *,
    explicit: Collection[str],
    full_access: bool,
    is_owner: bool,
    settings: Settings,
    now: datetime,
) -> dict[str, Any]:
    """``fields`` with the consent columns the write leaves behind.

    ``fields`` holds the keys the write sets (all of them for a create or a merged PATCH); a
    missing ``gtin`` or ``catalog_product_id`` stays as stored. ``explicit`` names the keys the
    caller actually sent: only an explicit flag can consent or withdraw, a merged value cannot.
    """
    current = _state_of(row)
    product: uuid.UUID | None = fields.get("catalog_product_id", current.product_id)
    request = ConsentRequest(
        shared=fields.get("gtin_link_shared") if "gtin_link_shared" in explicit else None,
        version=(
            fields.get("gtin_link_consent_version")
            if "gtin_link_consent_version" in explicit
            else None
        ),
    )
    try:
        state = resolve_consent(
            current,
            fields.get("gtin", current.gtin),
            product,
            request,
            full_access=full_access,
            is_owner=is_owner,
            supported_versions=settings.gtin_link_consent_versions,
            contributions_enabled=settings.catalog_contributions_enabled,
            now=now,
        )
    except ConsentError as exc:
        status = 403 if exc.code == "forbidden_field" else 422
        raise AppError(status, exc.code, _MESSAGES[exc.code]) from None
    return {
        **fields,
        "gtin_link_shared": state.shared,
        "gtin_link_consent_version": state.consent_version,
        "gtin_link_consented_at": state.consented_at,
    }


def with_rest_consent(
    row: Medication | None,
    fields: dict[str, Any],
    explicit: Collection[str],
    settings: Settings,
    *,
    is_owner: bool,
    now: datetime,
) -> dict[str, Any]:
    """:func:`with_consent` for REST writes.

    REST reaches only the caller's own and co-guarded profiles (editors and viewers use sync),
    so the writer always has full access; ``is_owner`` tells the owner from a co-guardian.
    """
    return with_consent(
        row,
        fields,
        explicit=explicit,
        full_access=True,
        is_owner=is_owner,
        settings=settings,
        now=now,
    )


async def reset_consent_in_profiles(
    session: AsyncSession, profile_ids: Collection[uuid.UUID]
) -> int:
    """Withdraw the contribution consent of every medication of ``profile_ids``.

    Consent follows the person who gave it: when a profile passes to another guardian, or its
    owner asked to delete the account, nobody is counted for a link they did not confirm. It is
    a versioned update journaled into the profile's scope, so every device sees the reset. The
    caller holds the journal lock of the scope's owner.
    """
    if not profile_ids:
        return 0
    rows = (
        await session.execute(
            update(Medication)
            .where(Medication.profile_id.in_(profile_ids), Medication.gtin_link_shared.is_(True))
            .values(
                gtin_link_shared=False,
                gtin_link_consent_version=None,
                gtin_link_consented_at=None,
                version=Medication.version + 1,
                updated_at=func.now(),
            )
            .returning(Medication.profile_id, Medication.id)
            .execution_options(synchronize_session=False)
        )
    ).all()
    by_profile: dict[uuid.UUID, list[uuid.UUID]] = {}
    for profile_id, medication_id in rows:
        by_profile.setdefault(profile_id, []).append(medication_id)
    for profile_id, medication_ids in by_profile.items():
        await record_changes(session, profile_id, "medication", medication_ids, "upsert")
    return len(rows)
