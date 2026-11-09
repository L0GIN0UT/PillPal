"""Consensus settings (D8): defaults and validation."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from tests.conftest import make_settings


def test_defaults_are_the_owner_decision_d8() -> None:
    settings = make_settings()
    assert settings.consensus_min_confirmations == 3
    assert settings.consensus_dispute_min == 2


@pytest.mark.parametrize(
    "name",
    [
        "consensus_min_confirmations",
        "consensus_dispute_min",
        "ingest_page_max_items",
        "ingest_max_items",
        "admin_page_max",
    ],
)
def test_thresholds_and_caps_must_be_positive(name: str) -> None:
    with pytest.raises(ValidationError):
        make_settings(**{name: 0})


def test_thresholds_come_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CATALOG_CONSENSUS_MIN_CONFIRMATIONS", "5")
    monkeypatch.setenv("CATALOG_DATABASE_URL", "postgresql://u:p@127.0.0.1/x")
    from catalog.config import Settings

    assert Settings().consensus_min_confirmations == 5  # type: ignore[call-arg]
