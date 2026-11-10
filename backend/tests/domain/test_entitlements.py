"""The effective-state rule of entitlements (ADR 0018 section 2). Pure, no fixtures."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import pytest

from app.domain.entitlements import Effective, effective, is_active

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
HOUR = timedelta(hours=1)


@dataclass(frozen=True)
class Row:
    kind: str
    expires_at: datetime | None = None
    revoked_at: datetime | None = None


def test_no_rows_means_nothing_is_effective() -> None:
    assert effective([], NOW) == Effective(ads_removed=False, limits_lifted=False)


@pytest.mark.parametrize(
    ("row", "active"),
    [
        (Row("ads_removed"), True),  # no expiry
        (Row("ads_removed", expires_at=NOW + HOUR), True),
        (Row("ads_removed", expires_at=NOW + timedelta(microseconds=1)), True),
        (Row("ads_removed", expires_at=NOW), False),  # exclusive: now < expires_at
        (Row("ads_removed", expires_at=NOW - HOUR), False),
        (Row("ads_removed", revoked_at=NOW - HOUR), False),
        (Row("ads_removed", revoked_at=NOW + HOUR), False),  # revoked at all, whenever
        (Row("ads_removed", expires_at=NOW + HOUR, revoked_at=NOW - HOUR), False),
    ],
)
def test_a_row_is_active_by_revocation_and_exclusive_expiry(row: Row, active: bool) -> None:
    assert is_active(row, NOW) is active
    assert effective([row], NOW).ads_removed is active


def test_kinds_are_independent() -> None:
    assert effective([Row("ads_removed")], NOW) == Effective(True, False)
    assert effective([Row("limits_lifted")], NOW) == Effective(False, True)
    both = [Row("ads_removed"), Row("limits_lifted")]
    assert effective(both, NOW) == Effective(True, True)


def test_one_active_row_is_enough_among_dead_ones() -> None:
    rows = [
        Row("ads_removed", expires_at=NOW - HOUR),
        Row("ads_removed", revoked_at=NOW - HOUR),
        Row("ads_removed", expires_at=NOW + HOUR),
    ]
    assert effective(rows, NOW).ads_removed is True


def test_an_unknown_kind_grants_nothing() -> None:
    assert effective([Row("something_else")], NOW) == Effective(False, False)
