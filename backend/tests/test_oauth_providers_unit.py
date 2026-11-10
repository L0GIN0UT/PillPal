"""The test double, the registry and the passwordless sentinel (no database, no Redis)."""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest

from app.domain.passwords import UNUSABLE_PASSWORD_HASH
from app.errors import AppError
from app.oauth.base import VerifiedIdentity
from app.oauth.fake import FakeProvider, nonce_digest
from app.oauth.registry import ProviderRegistry
from app.security import PasswordHasher
from tests.conftest import make_settings

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
NONCE = "n" * 43


def assertion(**claims: object) -> str:
    return json.dumps({"sub": "subject-1", "nonce": nonce_digest(NONCE), **claims})


async def verify(raw: str, nonce: str | None = NONCE) -> VerifiedIdentity:
    return await FakeProvider("vk_id").verify(
        raw, nonce=nonce, platform="android", code_verifier=None, now=NOW
    )


async def test_the_fake_accepts_a_good_assertion() -> None:
    identity = await verify(assertion(email=" Ann@Example.com ", email_verified=True, jti="j1"))
    assert identity.provider == "vk_id"
    assert identity.subject == "subject-1"
    assert identity.email == "ann@example.com"
    assert identity.email_verified is True
    assert identity.assertion_id == "j1"


async def test_an_address_counts_only_when_verified() -> None:
    assert (await verify(assertion(email="a@example.com"))).email_verified is False
    assert (await verify(assertion(email_verified=True))).email_verified is False


@pytest.mark.parametrize(
    "raw",
    [
        "not json",
        "[]",
        json.dumps({"nonce": nonce_digest(NONCE)}),  # no subject
        json.dumps({"sub": "", "nonce": nonce_digest(NONCE)}),
        json.dumps({"sub": "x" * 256, "nonce": nonce_digest(NONCE)}),
        json.dumps({"sub": "s", "nonce": "wrong"}),
        json.dumps({"sub": "s"}),
        json.dumps({"sub": "s", "nonce": nonce_digest(NONCE), "exp": "soon"}),
        json.dumps({"sub": "s", "nonce": nonce_digest(NONCE), "exp": NOW.timestamp() - 1}),
        json.dumps({"sub": "s", "nonce": nonce_digest(NONCE), "exp": NOW.timestamp()}),
    ],
)
async def test_the_fake_refuses_bad_assertions(raw: str) -> None:
    with pytest.raises(AppError) as info:
        await verify(raw)
    assert info.value.code == "invalid_provider_token"
    assert info.value.status_code == 401


async def test_the_fake_needs_the_raw_nonce() -> None:
    with pytest.raises(AppError) as info:
        await verify(assertion(), nonce=None)
    assert info.value.code == "invalid_provider_token"


async def test_the_fake_can_play_a_provider_timeout() -> None:
    with pytest.raises(AppError) as info:
        await verify(assertion(fail="unreachable"))
    assert (info.value.status_code, info.value.code) == (503, "provider_unreachable")


async def test_the_default_lifetime_is_short() -> None:
    identity = await verify(assertion())
    assert NOW < identity.expires_at <= NOW + timedelta(minutes=10)


def test_the_registry_needs_the_flag_the_matrix_and_a_verifier() -> None:
    off = ProviderRegistry(make_settings(oauth_fake_provider=True))
    assert off.available("android") == []
    on = ProviderRegistry(make_settings(feature_oauth=True, oauth_fake_provider=True))
    assert on.available("android") == ["vk_id", "yandex_id"]
    assert on.available("ios") == []
    assert on.get("vk_id", "android") is not None
    assert on.get("apple", "ios") is None  # not a provider of RU
    assert on.get("vk_id", "ios") is None  # not on that platform
    assert on.get("facebook", "android") is None
    eu = ProviderRegistry(make_settings(region="eu", feature_oauth=True, oauth_fake_provider=True))
    assert eu.available("ios") == ["apple", "google"]
    assert eu.get("vk_id", "android") is None
    # Without a verifier nothing is offered, however the flag is set (real ones: 5.8, 5.9).
    bare = ProviderRegistry(make_settings(feature_oauth=True))
    assert bare.available("android") == []


# --- the sentinel (ADR 0017 section 7) ----------------------------------------------------------


class _Spy:
    """Wraps the Argon2 object and records the hashes it is asked to parse."""

    def __init__(self, inner: Any, seen: list[str]) -> None:
        self._inner = inner
        self._seen = seen

    def verify(self, target: str, password: str) -> bool:
        self._seen.append(target)
        return bool(self._inner.verify(target, password))

    def hash(self, password: str) -> str:
        return str(self._inner.hash(password))

    def check_needs_rehash(self, target: str) -> bool:
        self._seen.append(target)
        return bool(self._inner.check_needs_rehash(target))


class SpyHasher(PasswordHasher):
    """Records what reaches the Argon2 parser."""

    def __init__(self) -> None:
        super().__init__(make_settings())
        self.verified: list[str] = []
        self._hasher = _Spy(self._hasher, self.verified)  # type: ignore[assignment]


async def test_the_sentinel_never_verifies_and_costs_a_dummy_verify() -> None:
    hasher = SpyHasher()
    assert await hasher.verify(UNUSABLE_PASSWORD_HASH, "anything at all") is False
    assert await hasher.verify(UNUSABLE_PASSWORD_HASH, "") is False
    # The Argon2 parser only ever saw the dummy hash, exactly as for an unknown account.
    assert hasher.verified == [hasher._dummy_hash, hasher._dummy_hash]
    unknown = SpyHasher()
    assert await unknown.verify(None, "anything at all") is False
    assert unknown.verified == [unknown._dummy_hash]


async def test_the_sentinel_is_not_parsed_or_rehashed() -> None:
    hasher = SpyHasher()
    assert hasher.needs_rehash(UNUSABLE_PASSWORD_HASH) is False
    assert hasher.verified == []  # the parser never saw the sentinel
    stored = await hasher.hash("a real password")
    assert await hasher.verify(stored, "a real password") is True
    assert await hasher.verify(stored, "another one") is False
    assert hasher.verified == [stored, stored]
