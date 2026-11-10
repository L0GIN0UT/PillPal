"""Consent kinds, sources and bounds (``docs/phase5-plan.md`` 5.2a). Pure: no IO."""

from __future__ import annotations

from typing import Literal, get_args

ConsentKind = Literal["health_data", "terms", "privacy", "catalog_contribution"]
ConsentSource = Literal["registration", "in_app", "oauth_signup", "medication_link"]

CONSENT_KINDS: tuple[str, ...] = get_args(ConsentKind)
CONSENT_SOURCES: tuple[str, ...] = get_args(ConsentSource)
CONTRIBUTION_KIND = "catalog_contribution"
# Kinds every account gives to use the service; the catalog contribution is optional and is
# recorded where the user ticks it (milestone 5.2b).
BASELINE_KINDS: tuple[str, ...] = ("health_data", "terms", "privacy")
# A sanity bound for the ``version`` column and the settings: versions count texts, not events.
MAX_CONSENT_VERSION = 1000
