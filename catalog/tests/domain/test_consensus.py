"""decide(): the pinned order of ADR 0014 section 4 (D8: N = 3, dispute at 2). Pure, no fixtures."""

from __future__ import annotations

import uuid

import pytest

from catalog.domain.consensus import (
    CurrentDecision,
    Decision,
    Thresholds,
    decide,
)

A = uuid.UUID(int=1)
B = uuid.UUID(int=2)
C = uuid.UUID(int=3)
T = Thresholds(promote_at=3, dispute_at=2)


def _auto(status: str, product: uuid.UUID | None, reason: str) -> Decision:
    return Decision(status, product, "auto", reason)  # type: ignore[arg-type]


def test_locked_is_checked_first_and_ignores_counts_and_official() -> None:
    current = CurrentDecision("locked", A, "admin")
    got = decide(official=B, counts={B: 9, C: 9}, current=current, thresholds=T)
    assert got == Decision("locked", A, "admin", "admin_lock")


def test_an_admin_rejection_is_not_overridden_by_counts() -> None:
    current = CurrentDecision("rejected", None, "admin")
    got = decide(official=None, counts={A: 9}, current=current, thresholds=T)
    assert got == Decision("rejected", None, "admin", "admin_reject")


def test_official_without_a_competitor_at_n_is_promoted_to_the_official_product() -> None:
    got = decide(official=A, counts={B: 2}, current=None, thresholds=T)
    assert got == _auto("promoted", A, "official_source")


def test_two_young_accounts_cannot_hide_an_official_gtin() -> None:
    # B has the dispute minimum (2) but not N: the official link stands.
    assert decide(official=A, counts={B: 2, C: 2}, current=None, thresholds=T).status == "promoted"


def test_official_with_a_competitor_at_n_is_disputed() -> None:
    got = decide(official=A, counts={A: 1, B: 3}, current=None, thresholds=T)
    assert got == _auto("disputed", None, "competitor_over_official")


def test_the_official_product_itself_reaching_n_is_not_a_dispute() -> None:
    assert decide(official=A, counts={A: 5}, current=None, thresholds=T).status == "promoted"


def test_a_promotion_is_sticky_when_counts_drop() -> None:
    current = CurrentDecision("promoted", A, "auto")
    got = decide(official=None, counts={}, current=current, thresholds=T)
    assert got == _auto("promoted", A, "sticky_promotion")


def test_a_promotion_survives_two_young_competitors() -> None:
    current = CurrentDecision("promoted", A, "auto")
    got = decide(official=None, counts={B: 2, C: 2}, current=current, thresholds=T)
    assert got.status == "promoted"
    assert got.product_id == A


def test_a_promoted_link_is_disputed_when_a_competitor_reaches_n() -> None:
    current = CurrentDecision("promoted", A, "auto")
    got = decide(official=None, counts={A: 3, B: 3}, current=current, thresholds=T)
    assert got == _auto("disputed", None, "competitor_over_promoted")


def test_an_admin_promotion_is_sticky_like_a_consensus_one() -> None:
    current = CurrentDecision("promoted", A, "admin")
    assert decide(official=None, counts={}, current=current, thresholds=T).status == "promoted"


def test_dispute_at_two_for_a_runner_up() -> None:
    got = decide(official=None, counts={A: 3, B: 2}, current=None, thresholds=T)
    assert got == _auto("disputed", None, "competing_confirmations")


def test_two_against_two_is_a_dispute_before_any_promotion() -> None:
    assert decide(official=None, counts={A: 2, B: 2}, current=None, thresholds=T).status == (
        "disputed"
    )


def test_n_confirmations_promote_the_top_product() -> None:
    got = decide(official=None, counts={A: 3, B: 1}, current=None, thresholds=T)
    assert got == _auto("promoted", A, "consensus_threshold")


def test_below_n_is_pending() -> None:
    got = decide(official=None, counts={A: 2}, current=None, thresholds=T)
    assert got == _auto("pending", None, "below_threshold")


def test_no_counts_and_no_history_is_pending() -> None:
    assert decide(official=None, counts={}, current=None, thresholds=T).status == "pending"


def test_a_dispute_that_lost_its_counts_falls_back_to_pending() -> None:
    current = CurrentDecision("disputed", None, "auto")
    assert decide(official=None, counts={A: 1}, current=current, thresholds=T).status == "pending"


@pytest.mark.parametrize(("promote_at", "dispute_at"), [(0, 2), (3, 0), (-1, 1)])
def test_thresholds_must_be_positive(promote_at: int, dispute_at: int) -> None:
    with pytest.raises(ValueError, match="at least 1"):
        Thresholds(promote_at=promote_at, dispute_at=dispute_at)


def test_a_tie_at_the_top_is_decided_by_the_product_id_not_by_input_order() -> None:
    forward = decide(official=None, counts={A: 3, B: 3}, current=None, thresholds=T)
    backward = decide(official=None, counts={B: 3, A: 3}, current=None, thresholds=T)
    assert forward == backward
    assert forward.status == "disputed"
