"""What a revoke attempt means for the sweep (ADR 0017 section 9): done, try again later, or never
possible (the stored blob cannot be opened). No database."""

from __future__ import annotations

import uuid

import httpx

from app.services.data_encryption import DataKeyring
from app.services.provider_tokens import REFRESH_PURPOSE, ProviderTokens, RevokeOutcome
from tests.conftest import make_settings
from tests.oauth_real_helpers import APPLE_SETTINGS, NOW, REFRESH_TOKEN
from tests.oauth_real_helpers import AppleEndpoints as Apple

SETTINGS = make_settings(**APPLE_SETTINGS)


def sealed_token(identity_id: uuid.UUID) -> bytes:
    keyring = DataKeyring.from_settings(SETTINGS)
    assert keyring is not None
    return keyring.encrypt(REFRESH_PURPOSE, identity_id, REFRESH_TOKEN.encode())


def tokens_for(apple: Apple) -> ProviderTokens:
    return ProviderTokens(apple.client(), DataKeyring.from_settings(SETTINGS))


async def test_an_accepted_revoke_is_revoked() -> None:
    identity_id = uuid.uuid4()
    outcome = await tokens_for(Apple()).revoke_outcome(
        "apple", identity_id, sealed_token(identity_id), NOW
    )
    assert outcome is RevokeOutcome.REVOKED


async def test_a_refusing_apple_is_a_failure_to_retry() -> None:
    apple = Apple()
    apple.revoke_responses = [httpx.Response(500), httpx.Response(500)]
    identity_id = uuid.uuid4()
    outcome = await tokens_for(apple).revoke_outcome(
        "apple", identity_id, sealed_token(identity_id), NOW
    )
    assert outcome is RevokeOutcome.FAILED


async def test_a_blob_that_cannot_be_opened_is_permanent() -> None:
    apple = Apple()
    for blob in (
        b"garbage",
        sealed_token(uuid.uuid4()),
    ):  # not sealed at all / sealed for another id
        outcome = await tokens_for(apple).revoke_outcome("apple", uuid.uuid4(), blob, NOW)
        assert outcome is RevokeOutcome.UNUSABLE
    assert apple.calls == []  # Apple is not asked about what cannot be read


async def test_a_token_of_a_provider_that_has_none_to_revoke_is_permanent() -> None:
    outcome = await tokens_for(Apple()).revoke_outcome("google", uuid.uuid4(), b"x", NOW)
    assert outcome is RevokeOutcome.UNUSABLE


async def test_without_a_client_or_a_keyring_the_token_waits() -> None:
    identity_id = uuid.uuid4()
    keyring = DataKeyring.from_settings(SETTINGS)
    outcomes = [
        await ProviderTokens(None, keyring).revoke_outcome(
            "apple", identity_id, sealed_token(identity_id), NOW
        ),
        await ProviderTokens(Apple().client(), None).revoke_outcome(
            "apple", identity_id, sealed_token(identity_id), NOW
        ),
    ]
    assert outcomes == [RevokeOutcome.FAILED, RevokeOutcome.FAILED]


async def test_revoke_keeps_answering_a_bool() -> None:
    identity_id = uuid.uuid4()
    tokens = tokens_for(Apple())
    assert await tokens.revoke("apple", identity_id, sealed_token(identity_id), NOW) is True
    assert await tokens.revoke("apple", identity_id, b"garbage", NOW) is False


async def test_a_keyring_without_the_old_key_keeps_the_token() -> None:
    # A configuration problem (the key that sealed it was removed), not damage: it may open again.
    identity_id = uuid.uuid4()
    blob = sealed_token(identity_id)
    other = make_settings(
        **APPLE_SETTINGS,
        data_encryption_keys={2: SETTINGS.data_encryption_keys[2]},
        data_encryption_key_id=2,
    )
    apple = Apple()
    tokens = ProviderTokens(apple.client(), DataKeyring.from_settings(other))
    outcome = await tokens.revoke_outcome("apple", identity_id, blob, NOW)
    assert outcome is RevokeOutcome.FAILED
    assert apple.calls == []
