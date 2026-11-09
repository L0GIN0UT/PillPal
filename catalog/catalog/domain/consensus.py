"""The GTIN link decision rule (ADR 0014 section 4, owner decision D8). Pure: no IO, no clock.

``decide`` is evaluated for a GTIN whenever an ingest touches it. The rows of the ADR's table are
checked **in this order and the first match wins**; the order is pinned by ``tests/domain``:

1. an admin lock (and an admin rejection) is final: counts are ignored;
2. an official source row: the official product stands, unless *another* product reaches N;
3. an already promoted link is sticky, unless another product reaches N;
4. a runner-up with at least ``dispute_at`` confirmations: disputed;
5. the top product with at least ``promote_at`` confirmations: promoted;
6. otherwise pending.

Two accounts that are too young to count therefore never hide an official or a promoted GTIN:
only a competitor reaching N does. The module never sees a person, a region or a device: its
inputs are product ids and counts.
"""

from __future__ import annotations

import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal

Status = Literal["pending", "promoted", "disputed", "rejected", "locked"]
DecidedBy = Literal["auto", "admin"]

# Stable reason codes stored in ``gtin_link_decisions.reason_code`` (CHECK ``^[a-z_]{1,64}$``).
REASON_ADMIN_LOCK = "admin_lock"
REASON_ADMIN_REJECT = "admin_reject"
REASON_OFFICIAL = "official_source"
REASON_COMPETITOR_OVER_OFFICIAL = "competitor_over_official"
REASON_STICKY = "sticky_promotion"
REASON_COMPETITOR_OVER_PROMOTED = "competitor_over_promoted"
REASON_COMPETING = "competing_confirmations"
REASON_THRESHOLD = "consensus_threshold"
REASON_BELOW = "below_threshold"


@dataclass(frozen=True)
class Thresholds:
    promote_at: int
    dispute_at: int

    def __post_init__(self) -> None:
        if self.promote_at < 1 or self.dispute_at < 1:
            raise ValueError("thresholds must be at least 1")


@dataclass(frozen=True)
class CurrentDecision:
    """What is stored for the GTIN before this evaluation."""

    status: Status
    product_id: uuid.UUID | None
    decided_by: DecidedBy


@dataclass(frozen=True)
class Decision:
    status: Status
    product_id: uuid.UUID | None
    decided_by: DecidedBy
    reason_code: str


def _auto(status: Status, product_id: uuid.UUID | None, reason: str) -> Decision:
    return Decision(status, product_id, "auto", reason)


def _final_admin_decision(current: CurrentDecision | None) -> Decision | None:
    if current is None:
        return None
    if current.status == "locked":
        return Decision("locked", current.product_id, "admin", REASON_ADMIN_LOCK)
    if current.status == "rejected" and current.decided_by == "admin":
        return Decision("rejected", None, "admin", REASON_ADMIN_REJECT)
    return None


def _competitor_at(counts: Mapping[uuid.UUID, int], standing: uuid.UUID, promote_at: int) -> bool:
    return any(n >= promote_at for product, n in counts.items() if product != standing)


def _ranked(counts: Mapping[uuid.UUID, int]) -> list[tuple[uuid.UUID, int]]:
    # Highest count first; the id breaks ties so the input order never matters.
    return sorted(counts.items(), key=lambda item: (-item[1], item[0].int))


def decide(
    official: uuid.UUID | None,
    counts: Mapping[uuid.UUID, int],
    current: CurrentDecision | None,
    thresholds: Thresholds,
) -> Decision:
    """The decision for one GTIN. ``counts`` maps product id to confirmations (all regions)."""
    final = _final_admin_decision(current)
    if final is not None:
        return final
    if official is not None:
        if _competitor_at(counts, official, thresholds.promote_at):
            return _auto("disputed", None, REASON_COMPETITOR_OVER_OFFICIAL)
        return _auto("promoted", official, REASON_OFFICIAL)
    if current is not None and current.status == "promoted" and current.product_id is not None:
        if _competitor_at(counts, current.product_id, thresholds.promote_at):
            return _auto("disputed", None, REASON_COMPETITOR_OVER_PROMOTED)
        return _auto("promoted", current.product_id, REASON_STICKY)
    ranked = _ranked(counts)
    if len(ranked) > 1 and ranked[1][1] >= thresholds.dispute_at:
        return _auto("disputed", None, REASON_COMPETING)
    if ranked and ranked[0][1] >= thresholds.promote_at:
        return _auto("promoted", ranked[0][0], REASON_THRESHOLD)
    return _auto("pending", None, REASON_BELOW)
