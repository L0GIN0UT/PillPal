"""Contribution consent follows the (gtin, product) pair (ADR 0014 §2, ADR 0015 §4): pure rules."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest

from app.domain.link_consent import (
    ConsentError,
    ConsentRequest,
    LinkState,
    consent_keys_forbidden,
    resolve_consent,
)

GTIN = "04600000000015"
OTHER_GTIN = "04600000000022"
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
    is_owner: bool = True,
    enabled: bool = True,
) -> LinkState:
    return resolve_consent(
        current,
        gtin,
        product,
        ConsentRequest(shared, version),
        full_access=full_access,
        is_owner=is_owner,
        supported_versions=SUPPORTED,
        contributions_enabled=enabled,
        now=NOW,
    )


def test_a_grant_records_the_version_and_the_server_time() -> None:
    assert resolve(LINKED, shared=True, version=2) == LinkState(GTIN, PRODUCT, True, 2, NOW)


def test_a_grant_may_come_with_the_upsert_that_creates_the_link() -> None:
    state = resolve(UNLINKED, shared=True, version=1)
    assert (state.shared, state.consent_version, state.consented_at) == (True, 1, NOW)


def test_the_flag_without_a_version_is_not_a_grant() -> None:
    # A stale device echoing old state (shared=true, no version) must never re-grant.
    assert resolve(LINKED, shared=True) == LINKED
    assert resolve(UNLINKED, gtin=None, product=None, shared=True) == UNLINKED


def test_a_stale_echo_after_a_re_link_applies_the_link_and_not_the_consent() -> None:
    state = resolve(SHARED, gtin=OTHER_GTIN, shared=True)
    assert state == LinkState(OTHER_GTIN, PRODUCT, False, None, None)


@pytest.mark.parametrize(
    ("kwargs", "code"),
    [
        ({"version": 9}, "unsupported_consent_version"),
        ({"version": 1, "enabled": False}, "contributions_disabled"),
        ({"version": 1, "gtin": None}, "gtin_link_needs_gtin_and_product"),
        ({"version": 1, "product": None}, "gtin_link_needs_gtin_and_product"),
    ],
)
def test_an_invalid_grant_is_refused(kwargs: dict[str, object], code: str) -> None:
    with pytest.raises(ConsentError) as err:
        resolve(LINKED, shared=True, **kwargs)  # type: ignore[arg-type]
    assert err.value.code == code


def test_without_a_version_nothing_is_validated_even_when_contributions_are_off() -> None:
    assert resolve(LINKED, shared=True, enabled=False) == LINKED


def test_repeating_a_consent_for_the_same_pair_keeps_the_original_time() -> None:
    assert resolve(SHARED, shared=True, version=1) == SHARED
    assert resolve(SHARED, shared=True) == SHARED
    assert resolve(SHARED, shared=True, version=9) == SHARED  # nothing is granted again


def test_an_explicit_false_always_withdraws() -> None:
    assert resolve(SHARED, shared=False) == LinkState(GTIN, PRODUCT, False, None, None)
    assert resolve(SHARED, shared=False, version=1) == LinkState(GTIN, PRODUCT, False, None, None)


def test_a_version_alone_changes_nothing() -> None:
    assert resolve(LINKED, version=1) == LINKED
    assert resolve(SHARED, version=2) == SHARED


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


RESTRICTED = "02000000000015"  # an RCN-13 prefix: private to the user (D3)
BAD_CHECK_DIGIT = "04600000000011"


@pytest.mark.parametrize("gtin", [RESTRICTED, BAD_CHECK_DIGIT, "00000000000000"])
def test_a_grant_on_a_gtin_that_is_not_shareable_is_refused(gtin: str) -> None:
    with pytest.raises(ConsentError) as err:
        resolve(LINKED, gtin=gtin, shared=True, version=1)
    assert err.value.code == "gtin_not_shareable"


def test_withdrawal_and_an_existing_consent_still_pass_for_any_gtin() -> None:
    held = LinkState(RESTRICTED, PRODUCT, True, 1, T0)
    assert resolve(held, gtin=RESTRICTED, shared=True, version=1) == held
    assert resolve(held, gtin=RESTRICTED, shared=False) == LinkState(
        RESTRICTED, PRODUCT, False, None, None
    )
    assert resolve(LINKED, gtin=RESTRICTED, shared=True) == LinkState(
        RESTRICTED, PRODUCT, False, None, None
    )  # not a grant


def test_a_role_without_full_access_never_carries_consent() -> None:
    state = resolve(SHARED, gtin=OTHER_GTIN, shared=True, version=1, full_access=False)
    assert state == LinkState(OTHER_GTIN, PRODUCT, False, None, None)
    assert resolve(SHARED, full_access=False) == SHARED


@pytest.mark.parametrize(
    ("full_access", "sent", "forbidden"),
    [
        (False, {"gtin_link_shared"}, True),
        (False, {"gtin_link_consent_version"}, True),
        (False, {"gtin_link_shared", "gtin_link_consent_version"}, True),
        (False, {"gtin", "notes"}, False),
        (False, set(), False),
        (True, {"gtin_link_shared", "gtin_link_consent_version"}, False),
    ],
)
def test_a_role_without_full_access_may_not_send_consent_keys(
    full_access: bool, sent: set[str], forbidden: bool
) -> None:
    assert consent_keys_forbidden(full_access, sent) is forbidden


def test_a_co_guardian_cannot_grant() -> None:
    with pytest.raises(ConsentError) as err:
        resolve(LINKED, shared=True, version=1, is_owner=False)
    assert err.value.code == "forbidden_field"


def test_a_co_guardian_echo_of_a_stored_grant_is_not_refused() -> None:
    assert resolve(SHARED, shared=True, version=1, is_owner=False) == SHARED
    assert resolve(SHARED, shared=True, is_owner=False) == SHARED


def test_a_co_guardian_may_clear_and_a_versionless_flag_is_not_a_grant() -> None:
    cleared = resolve(SHARED, shared=False, is_owner=False)
    assert (cleared.shared, cleared.consent_version) == (False, None)
    assert resolve(LINKED, shared=True, is_owner=False) == LINKED
