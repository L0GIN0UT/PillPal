"""Contribution consent follows the (gtin, product) pair (ADR 0014 §2, ADR 0015 §4): pure rules."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from app.domain.link_consent import (
    ConsentError,
    ConsentRequest,
    LinkState,
    flag_change_forbidden,
    resolve_consent,
)

GTIN = "04600000000011"
OTHER_GTIN = "04600000000028"
PRODUCT = uuid.UUID("00000000-0000-4000-8000-000000000001")
OTHER_PRODUCT = uuid.UUID("00000000-0000-4000-8000-000000000002")
T0 = datetime(2026, 11, 1, 8, 0, tzinfo=UTC)
NOW = T0 + timedelta(days=3)
SUPPORTED = frozenset({1, 2})

UNLINKED = LinkState(None, None, False, None, None)
LINKED = LinkState(GTIN, PRODUCT, False, None, None)
SHARED = LinkState(GTIN, PRODUCT, True, 1, T0)


def resolve(
    current: LinkState,
    *,
    gtin: str | None = GTIN,
    product: uuid.UUID | None = PRODUCT,
    shared: bool | None = None,
    version: int | None = None,
    full_access: bool = True,
) -> LinkState:
    return resolve_consent(
        current,
        gtin,
        product,
        ConsentRequest(shared, version),
        full_access=full_access,
        supported_versions=SUPPORTED,
        now=NOW,
    )


def test_a_full_access_upsert_that_sets_the_flag_records_version_and_server_time() -> None:
    state = resolve(LINKED, shared=True, version=2)
    assert state == LinkState(GTIN, PRODUCT, True, 2, NOW)


def test_the_flag_can_be_set_in_the_same_upsert_that_creates_the_link() -> None:
    state = resolve(UNLINKED, shared=True, version=1)
    assert (state.shared, state.consent_version, state.consented_at) == (True, 1, NOW)


def test_an_unsupported_version_is_refused() -> None:
    with pytest.raises(ConsentError) as err:
        resolve(LINKED, shared=True, version=9)
    assert err.value.code == "unsupported_consent_version"


def test_a_new_consent_needs_a_version() -> None:
    with pytest.raises(ConsentError) as err:
        resolve(LINKED, shared=True)
    assert err.value.code == "consent_version_required"


def test_the_flag_needs_both_the_gtin_and_the_product() -> None:
    for gtin, product in ((None, PRODUCT), (GTIN, None), (None, None)):
        with pytest.raises(ConsentError) as err:
            resolve(UNLINKED, gtin=gtin, product=product, shared=True, version=1)
        assert err.value.code == "gtin_link_needs_gtin_and_product"


def test_repeating_the_same_consent_keeps_the_original_time() -> None:
    assert resolve(SHARED, shared=True, version=1) == SHARED
    assert resolve(SHARED, shared=True) == SHARED  # an echo without the version


def test_a_newer_text_version_is_a_new_consent() -> None:
    state = resolve(SHARED, shared=True, version=2)
    assert (state.consent_version, state.consented_at) == (2, NOW)


def test_an_echo_of_a_version_that_is_no_longer_supported_does_not_fail() -> None:
    old = LinkState(GTIN, PRODUCT, True, 0, T0)
    assert resolve(old, shared=True, version=0) == old


def test_an_explicit_false_withdraws_the_consent() -> None:
    assert resolve(SHARED, shared=False) == LinkState(GTIN, PRODUCT, False, None, None)


def test_absent_flag_keeps_consent_while_the_pair_is_unchanged() -> None:
    assert resolve(SHARED) == SHARED


@pytest.mark.parametrize(
    ("gtin", "product"),
    [(OTHER_GTIN, PRODUCT), (GTIN, OTHER_PRODUCT), (None, PRODUCT), (GTIN, None), (None, None)],
)
def test_any_change_of_the_pair_resets_consent(gtin: str | None, product: uuid.UUID | None) -> None:
    state = resolve(SHARED, gtin=gtin, product=product)
    assert state == LinkState(gtin, product, False, None, None)


def test_a_full_access_upsert_may_re_consent_for_the_new_pair() -> None:
    state = resolve(SHARED, gtin=OTHER_GTIN, shared=True, version=1)
    assert state == LinkState(OTHER_GTIN, PRODUCT, True, 1, NOW)


def test_a_role_without_full_access_never_carries_consent() -> None:
    # Re-linking by an editor resets, even when the payload says true.
    state = resolve(SHARED, gtin=OTHER_GTIN, shared=True, version=1, full_access=False)
    assert state == LinkState(OTHER_GTIN, PRODUCT, False, None, None)


def test_a_role_without_full_access_leaves_an_unchanged_pair_alone() -> None:
    assert resolve(SHARED, full_access=False) == SHARED
    assert resolve(SHARED, shared=True, version=1, full_access=False) == SHARED


@pytest.mark.parametrize(
    ("full_access", "current", "requested", "forbidden"),
    [
        (False, False, True, True),
        (False, True, False, True),
        (False, True, True, False),
        (False, False, False, False),
        (False, True, None, False),
        (True, False, True, False),
        (True, True, False, False),
    ],
)
def test_only_full_access_roles_change_the_flag(
    full_access: bool, current: bool, requested: bool | None, forbidden: bool
) -> None:
    assert flag_change_forbidden(full_access, current, requested) is forbidden
