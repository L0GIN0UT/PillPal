"""Settings of the missed-dose detector."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from tests.conftest import make_settings


def test_defaults_follow_adr_0007() -> None:
    settings = make_settings()
    assert settings.detector_max_window_seconds == 600
    assert settings.detector_max_catchup_seconds == 6 * 3600
    assert settings.detector_profile_batch == 500
    assert settings.detector_alert_retention_hours == 72


def test_catch_up_must_cover_a_whole_window() -> None:
    with pytest.raises(ValidationError, match="DETECTOR_MAX_CATCHUP_SECONDS"):
        make_settings(detector_max_window_seconds=900, detector_max_catchup_seconds=600)


def test_alerts_are_kept_longer_than_the_catch_up_and_push_staleness() -> None:
    # Dedupe must outlive the horizon in which a late undo can still raise the alert.
    with pytest.raises(ValidationError, match="DETECTOR_ALERT_RETENTION_HOURS"):
        make_settings(detector_alert_retention_hours=6)
