"""Payments domain rules (ADR 0018 section 6): stores per region, product grants, account token."""

from __future__ import annotations

import uuid

import pytest

from app.domain.payments import (
    PRODUCT_GRANTS,
    STORES,
    app_account_token,
    stores_for,
)

KEY = bytes(range(32))
OTHER_KEY = bytes(range(1, 33))
USER = uuid.UUID("11111111-2222-4333-8444-555555555555")


def test_stores_per_region_follow_the_registry_table() -> None:
    assert stores_for("ru") == ("rustore", "app_store")
    assert stores_for("eu") == ("app_store", "google_play")


def test_rustore_is_never_available_in_eu_and_google_play_never_in_ru() -> None:
    assert "rustore" not in stores_for("eu")
    assert "google_play" not in stores_for("ru")
    assert set(STORES) == {"app_store", "rustore", "google_play"}


def test_the_remove_ads_product_grants_both_kinds() -> None:
    assert PRODUCT_GRANTS["remove_ads"] == ("ads_removed", "limits_lifted")


def test_the_account_token_is_stable_per_account_and_key() -> None:
    assert app_account_token(KEY, USER) == app_account_token(KEY, USER)


def test_the_account_token_differs_per_account_and_per_key() -> None:
    other_user = uuid.UUID("11111111-2222-4333-8444-555555555556")
    assert app_account_token(KEY, USER) != app_account_token(KEY, other_user)
    assert app_account_token(KEY, USER) != app_account_token(OTHER_KEY, USER)


def test_the_account_token_is_a_uuid_that_is_not_the_user_id() -> None:
    token = app_account_token(KEY, USER)
    assert isinstance(token, uuid.UUID)
    assert token != USER
    assert str(token) != str(USER)


@pytest.mark.parametrize("region", ["us", "", "RU"])
def test_an_unknown_region_has_no_stores(region: str) -> None:
    assert stores_for(region) == ()
