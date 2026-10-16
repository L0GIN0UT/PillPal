"""Settings of the relatives feature (links, invites, soft limits): defaults and validation."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from tests.conftest import make_settings

FINGERPRINT = ":".join(["AB"] * 32)
OTHER_FINGERPRINT = ":".join(["01"] * 32)


def test_defaults_follow_the_adrs() -> None:
    s = make_settings()
    assert s.invite_ttl_seconds == 7 * 24 * 3600
    assert s.guardian_invite_ttl_seconds == 24 * 3600
    assert s.invite_replay_window_seconds == 24 * 3600
    assert s.max_active_invites_per_profile == 5
    assert s.max_access_scopes_per_user == 100
    assert s.feature_soft_limits is False
    assert s.soft_limit_relatives == 3


@pytest.mark.parametrize("region", ["ru", "eu"])
def test_link_base_url_defaults_to_the_reserved_invalid_tld(region: str) -> None:
    s = make_settings(region=region)
    assert s.public_link_base_url == f"https://links-{region}.pillpal.invalid"


def test_link_base_url_is_normalized() -> None:
    s = make_settings(public_link_base_url="https://Links.Example.com/")
    assert s.public_link_base_url == "https://links.example.com"


@pytest.mark.parametrize(
    "value",
    [
        "http://links.example.com",
        "https://links.example.com/path",
        "https://links.example.com?x=1",
        "https://links.example.com#frag",
        "https://user@links.example.com",
        "links.example.com",
        "https://",
    ],
)
def test_link_base_url_must_be_a_bare_https_origin(value: str) -> None:
    with pytest.raises(ValidationError, match="PUBLIC_LINK_BASE_URL"):
        make_settings(public_link_base_url=value)


def test_android_fingerprints_are_validated_and_normalized() -> None:
    lowered = FINGERPRINT.lower()
    s = make_settings(android_package_name="app.pillpal.example", android_cert_sha256s=[lowered])
    assert s.android_cert_sha256s == [FINGERPRINT]
    malformed = [
        "AB:CD",
        "ZZ:" + FINGERPRINT[3:],
        FINGERPRINT.replace(":", ""),
        FINGERPRINT + ":AA",
    ]
    for bad in malformed:
        with pytest.raises(ValidationError, match="ANDROID_CERT_SHA256S"):
            make_settings(android_cert_sha256s=[bad])


def test_prod_rejects_a_listed_debug_certificate() -> None:
    kwargs = {
        "android_cert_sha256s": [FINGERPRINT, OTHER_FINGERPRINT],
        "android_debug_cert_sha256s": [OTHER_FINGERPRINT],
    }
    assert make_settings(environment="dev", **kwargs).android_cert_sha256s  # allowed outside prod
    with pytest.raises(ValidationError, match="debug"):
        make_settings(environment="prod", **kwargs)


def test_apple_and_android_identifiers_are_validated() -> None:
    with pytest.raises(ValidationError, match="APPLE_TEAM_ID"):
        make_settings(apple_team_id="short")
    with pytest.raises(ValidationError, match="IOS_BUNDLE_ID"):
        make_settings(ios_bundle_id="not a bundle id")
    with pytest.raises(ValidationError, match="ANDROID_PACKAGE_NAME"):
        make_settings(android_package_name="no spaces allowed")
    s = make_settings(apple_team_id="ABCDE12345", ios_bundle_id="app.pillpal.example")
    assert (s.apple_team_id, s.ios_bundle_id) == ("ABCDE12345", "app.pillpal.example")
