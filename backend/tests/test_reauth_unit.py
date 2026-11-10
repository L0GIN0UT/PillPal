"""The freshness rule of a re-auth assertion (ADR 0017 section 8); no database, no Redis."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any, cast

import pytest

from app.services.oauth_verify import REPLAY_SKEW_SECONDS
from app.services.reauth import Reauthenticator
from tests.conftest import make_settings

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
MAX_AGE = 300


def reauthenticator() -> Reauthenticator:
    none = cast("Any", None)
    settings = make_settings(oauth_reauth_max_age_seconds=MAX_AGE)
    return Reauthenticator(none, settings, none, none, none)


@pytest.mark.parametrize(
    ("age_seconds", "fresh"),
    [
        (0, True),
        (MAX_AGE, True),
        (MAX_AGE + 1, False),
        (-REPLAY_SKEW_SECONDS, True),  # a little clock skew into the future
        (-REPLAY_SKEW_SECONDS - 1, False),  # a token from the future is not fresh
    ],
)
def test_freshness_window(age_seconds: int, fresh: bool) -> None:
    issued_at = NOW - timedelta(seconds=age_seconds)
    assert reauthenticator()._is_fresh(issued_at, NOW) is fresh


def test_an_assertion_without_an_issue_time_is_never_fresh() -> None:
    assert reauthenticator()._is_fresh(None, NOW) is False
