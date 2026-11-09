"""Applies the contribution-consent rule (``app.domain.link_consent``) to a medication write.

Sync push and REST both go through :func:`with_consent`, so a re-link resets the consent
whichever way it arrives, in the same versioned update (the owner's other devices get the
reset in their next pull). ``ConsentError`` becomes a stable 422.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from datetime import datetime
from typing import Any

from app.config import Settings
from app.db.models import Medication
from app.domain.link_consent import ConsentError, ConsentRequest, LinkState, resolve_consent
from app.errors import AppError

_MESSAGES = {
    "unsupported_consent_version": "This consent text version is not supported",
    "consent_version_required": "A consent needs the version of the text that was shown",
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
            supported_versions=settings.gtin_link_consent_versions,
            now=now,
        )
    except ConsentError as exc:
        raise AppError(422, exc.code, _MESSAGES[exc.code]) from None
    return {
        **fields,
        "gtin_link_shared": state.shared,
        "gtin_link_consent_version": state.consent_version,
        "gtin_link_consented_at": state.consented_at,
    }
