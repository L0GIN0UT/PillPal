"""The medication branch of sync push: keep-on-absent fields, comparison and consent helpers.

Kept apart from ``app.services.sync`` (file size, and so the rules read in one place). The
conflict rules and the authorization gate stay in ``SyncService``; these are pure helpers.
"""

from __future__ import annotations

from typing import Any

from app.domain.link_consent import consent_keys_forbidden
from app.domain.privacy import Role, is_full_access
from app.schemas.entities import MedicationData, MedicationFields

# Medication fields that keep their stored value when a push does not mention them: an installed
# app that predates them sends full state without them and must not wipe them (ADR 0015 §4).
# An explicit null clears. The older fields keep the full-state meaning. The value is merged
# against the stored row when the push is applied, not against a per-field clock: an old app's
# write that arrives after a newer client's keeps whatever the row holds by then.
KEEP_ON_ABSENT = frozenset(
    {
        "catalog_product_id",
        "catalog_package_id",
        "catalog_composition_id",
        "gtin",
        "manual_ingredients",
        "gtin_link_shared",
        "gtin_link_consent_version",
    }
)
# Not compared for "same payload". The consent keys are not part of the conflict key: the server
# decides what they do (a grant needs the version, an echo is a no-op), so a replay of an echo
# that changed nothing, or of a grant whose version is not stored back, must not look like a
# different write with the same key (``key_conflict``).
NOT_COMPARED = frozenset({"gtin_link_shared", "gtin_link_consent_version"})


def push_fields(data: MedicationData) -> tuple[dict[str, Any], set[str]]:
    """``(fields, sent)``: the values this push sets, and the keys the client actually sent."""
    sent = set(data.model_fields_set)
    fields = {
        key: value
        for key, value in data.model_dump(include=set(MedicationFields.model_fields)).items()
        if key not in KEEP_ON_ABSENT or key in sent
    }
    return fields, sent


def comparable(fields: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in fields.items() if key not in NOT_COMPARED}


def has_full_access(role: Role | None) -> bool:
    return role is not None and is_full_access(role)


def consent_refused(role: Role | None, sent: set[str]) -> bool:
    """A role without full access sent a consent key (``forbidden_field``, whatever is stored)."""
    return consent_keys_forbidden(has_full_access(role), sent)
