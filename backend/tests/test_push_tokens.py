"""``PUT/DELETE /v1/push-tokens/current`` (ADR 0008 §1)."""

from __future__ import annotations

import uuid
from dataclasses import replace

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.email import InMemoryEmailSender
from tests.grace_helpers import login, request_deletion
from tests.helpers import User, register
from tests.push_helpers import APNS_TOKEN, delete_token, fcm_token, put_token, rows, token_rows


async def test_register_creates_the_token_and_the_device(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await put_token(client, user, "phone-1")
    assert resp.status_code == 200, resp.text
    assert resp.json()["provider"] == "fcm"
    assert resp.json()["apns_environment"] is None
    assert "token" not in resp.json()  # never echoed back
    stored = await token_rows(engine, user)
    assert [(r.device_id, r.provider, r.token) for r in stored] == [
        ("phone-1", "fcm", fcm_token("phone-1"))
    ]
    devices = await rows(
        engine, "SELECT device_id FROM devices WHERE user_id = :u", u=uuid.UUID(user.id)
    )
    assert [d.device_id for d in devices] == ["phone-1"]


async def test_apns_token_needs_an_environment(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    resp = await put_token(
        client, user, provider="apns", token=APNS_TOKEN, apns_environment="sandbox"
    )
    assert resp.status_code == 200, resp.text
    assert resp.json() == {
        "provider": "apns",
        "apns_environment": "sandbox",
        "updated_at": resp.json()["updated_at"],
    }
    assert (await token_rows(engine, user))[0].apns_environment == "sandbox"


async def test_registering_again_replaces_the_token_of_the_device(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await put_token(client, user, "dev-1", token="first-token")
    await put_token(client, user, "dev-1", token="first-token")  # idempotent
    resp = await put_token(client, user, "dev-1", token="second-token")
    assert resp.status_code == 200
    assert [r.token for r in await token_rows(engine, user)] == ["second-token"]


async def test_the_same_device_can_switch_provider(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await put_token(client, user, "dev-1", token="fcm-first")
    resp = await put_token(
        client, user, "dev-1", provider="apns", token=APNS_TOKEN, apns_environment="production"
    )
    assert resp.status_code == 200
    stored = await token_rows(engine, user)
    assert [(r.provider, r.apns_environment) for r in stored] == [("apns", "production")]


@pytest.mark.parametrize(
    "body",
    [
        {"provider": "apns", "token": APNS_TOKEN},  # environment missing
        {"provider": "apns", "token": APNS_TOKEN, "apns_environment": "staging"},
        {"provider": "apns", "token": APNS_TOKEN.upper(), "apns_environment": "sandbox"},
        {"provider": "apns", "token": "ab" * 31, "apns_environment": "sandbox"},
        {"provider": "apns", "token": "ab" * 101, "apns_environment": "sandbox"},
        {"provider": "fcm", "token": "tok", "apns_environment": "sandbox"},
        {"provider": "fcm", "token": "has space"},
        {"provider": "fcm", "token": "../../etc"},
        {"provider": "fcm", "token": ""},
        {"provider": "fcm", "token": "a" * 4097},
        {"provider": "rustore", "token": "a/b"},
        {"provider": "webpush", "token": "tok"},
        {"provider": "fcm"},
        {"token": "tok"},
        {"provider": "fcm", "token": "tok", "user_id": str(uuid.uuid4())},  # extra=forbid
    ],
)
async def test_invalid_bodies_are_422(
    client: AsyncClient, engine: AsyncEngine, body: dict[str, str]
) -> None:
    user = await register(client)
    resp = await client.put("/v1/push-tokens/current", json=body, headers=user.device("dev-1"))
    assert resp.status_code == 422, resp.text
    assert await token_rows(engine) == []
    token = body.get("token")
    if token:
        assert token not in resp.text  # input is never echoed


async def test_longest_valid_tokens_are_accepted(client: AsyncClient) -> None:
    user = await register(client)
    assert (await put_token(client, user, token="a" * 4096)).status_code == 200
    long_apns = "ab" * 100
    resp = await put_token(
        client, user, "dev-2", provider="apns", token=long_apns, apns_environment="sandbox"
    )
    assert resp.status_code == 200


async def test_device_header_is_required_and_validated(client: AsyncClient) -> None:
    user = await register(client)
    body = {"provider": "fcm", "token": "tok"}
    missing = await client.put("/v1/push-tokens/current", json=body, headers=user.headers)
    assert missing.status_code == 422
    bad = await client.put(
        "/v1/push-tokens/current", json=body, headers={**user.headers, "X-Device-ID": "no spaces!"}
    )
    assert bad.status_code == 422
    assert (await client.delete("/v1/push-tokens/current", headers=user.headers)).status_code == 422


async def test_unauthenticated_requests_are_401(client: AsyncClient) -> None:
    body = {"provider": "fcm", "token": "tok"}
    headers = {"X-Device-ID": "dev-1"}
    assert (
        await client.put("/v1/push-tokens/current", json=body, headers=headers)
    ).status_code == 401
    assert (await client.delete("/v1/push-tokens/current", headers=headers)).status_code == 401
    bad = {**headers, "Authorization": "Bearer nonsense"}
    assert (await client.put("/v1/push-tokens/current", json=body, headers=bad)).status_code == 401


async def test_a_token_moving_to_another_account_is_reassigned(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    alice, bob = await register(client), await register(client)
    await put_token(client, alice, "alice-phone", token="shared-device-token")
    resp = await put_token(client, bob, "bob-phone", token="shared-device-token")
    assert resp.status_code == 200
    stored = await token_rows(engine)
    assert [(r.user_id, r.device_id) for r in stored] == [(uuid.UUID(bob.id), "bob-phone")]


async def test_a_token_moving_between_devices_of_one_account(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await put_token(client, user, "old-install", token="tok-1")
    await put_token(client, user, "new-install", token="tok-1")
    assert [r.device_id for r in await token_rows(engine, user)] == ["new-install"]


async def test_reassignment_cancels_the_old_accounts_pending_deliveries(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    from tests.push_outbox_helpers import insert_outbox

    alice, bob = await register(client), await register(client)
    await put_token(client, alice, "alice-phone", token="shared-device-token")
    await insert_outbox(engine, alice, alice.self_profile_id)
    await put_token(client, bob, "bob-phone", token="shared-device-token")
    assert await rows(engine, "SELECT id FROM push_outbox") == []


async def test_per_user_cap_is_enforced(
    client: AsyncClient, engine: AsyncEngine, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "push_max_tokens_per_user", 3)
    user, other = await register(client), await register(client)
    for n in range(3):
        assert (await put_token(client, user, f"dev-{n}")).status_code == 200
    over = await put_token(client, user, "dev-extra")
    assert over.status_code == 409
    assert over.json()["error"]["code"] == "too_many_push_tokens"
    # The fourth device left no trace, and an existing device can still rotate its token.
    assert len(await token_rows(engine, user)) == 3
    assert (await put_token(client, user, "dev-0", token="rotated")).status_code == 200
    # Another account has its own budget.
    assert (await put_token(client, other, "dev-0")).status_code == 200


async def test_taking_over_a_token_from_the_same_account_does_not_count_twice(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "push_max_tokens_per_user", 2)
    user = await register(client)
    await put_token(client, user, "dev-a", token="tok-a")
    await put_token(client, user, "dev-b", token="tok-b")
    # dev-c steals dev-a's token: net count stays 2, so it is allowed.
    assert (await put_token(client, user, "dev-c", token="tok-a")).status_code == 200


async def test_rejected_registration_does_not_leave_a_device_row_over_the_cap(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await put_token(client, user, "dev-1", provider="apns", token="bad token")
    assert resp.status_code == 422
    assert await rows(engine, "SELECT 1 FROM devices") == []


async def test_rustore_is_refused_outside_ru(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    assert (await put_token(client, user, provider="rustore", token="rs-token")).status_code == 200
    monkeypatch.setattr(settings, "region", "eu")
    resp = await put_token(client, user, "dev-2", provider="rustore", token="rs-token-2")
    assert resp.status_code == 422
    assert (await put_token(client, user, "dev-2", token="fcm-ok")).status_code == 200


async def test_delete_removes_only_this_device(client: AsyncClient, engine: AsyncEngine) -> None:
    user, other = await register(client), await register(client)
    await put_token(client, user, "dev-1")
    await put_token(client, user, "dev-2")
    await put_token(client, other, "dev-1")
    assert (await delete_token(client, user, "dev-1")).status_code == 204
    assert (await delete_token(client, user, "dev-1")).status_code == 204  # idempotent
    assert [r.device_id for r in await token_rows(engine, user)] == ["dev-2"]
    assert len(await token_rows(engine, other)) == 1  # another account's same device id


async def test_registration_is_rate_limited(client: AsyncClient) -> None:
    user = await register(client)
    codes = [
        (await put_token(client, user, "dev-1", token=f"tok-{n}")).status_code for n in range(60)
    ]
    assert 429 in codes


async def _login_on(client: AsyncClient, user: User, device: str) -> User:
    resp = await login(client, user.email, user.password, device)
    assert resp.status_code == 200, resp.text
    tokens = resp.json()
    return replace(user, access_token=tokens["access_token"], refresh_token=tokens["refresh_token"])


async def test_logout_removes_the_token_of_the_device_bound_to_the_refresh_token(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    first = await register(client)
    phone = await _login_on(client, first, "phone")
    tablet = await _login_on(client, first, "tablet")
    await put_token(client, phone, "phone")
    await put_token(client, tablet, "tablet")
    resp = await client.post("/v1/auth/logout", json={"refresh_token": phone.refresh_token})
    assert resp.status_code == 204
    assert [r.device_id for r in await token_rows(engine, first)] == ["tablet"]


async def test_logout_of_a_session_without_a_device_removes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)  # the first session was opened without X-Device-ID
    await put_token(client, user, "phone")
    resp = await client.post("/v1/auth/logout", json={"refresh_token": user.refresh_token})
    assert resp.status_code == 204
    assert len(await token_rows(engine, user)) == 1


async def test_logout_with_an_unknown_refresh_token_removes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await put_token(client, user, "phone")
    await client.post("/v1/auth/logout", json={"refresh_token": "x" * 40})
    assert len(await token_rows(engine, user)) == 1


async def test_deletion_request_removes_every_token_of_the_account(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, other = await register(client), await register(client)
    await put_token(client, user, "dev-1")
    await put_token(client, user, "dev-2")
    await put_token(client, other, "dev-1")
    assert (await request_deletion(client, user)).status_code == 204
    assert await token_rows(engine, user) == []
    assert len(await token_rows(engine, other)) == 1


async def test_refresh_token_reuse_removes_the_tokens_of_the_revoked_familys_devices(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    first = await register(client)
    phone = await _login_on(client, first, "phone")  # the family that gets stolen
    tablet = await _login_on(client, first, "tablet")  # another family: stays
    await put_token(client, phone, "phone")
    await put_token(client, tablet, "tablet")
    bystander = await register(client)
    await put_token(client, bystander, "bystander-phone")
    rotated = await client.post("/v1/auth/refresh", json={"refresh_token": phone.refresh_token})
    assert rotated.status_code == 200
    replay = await client.post("/v1/auth/refresh", json={"refresh_token": phone.refresh_token})
    assert replay.json()["error"]["code"] == "token_reused"
    assert [r.device_id for r in await token_rows(engine, first)] == ["tablet"]
    assert len(await token_rows(engine, bystander)) == 1


async def test_password_reset_removes_every_token_of_the_account(
    client: AsyncClient, engine: AsyncEngine, email_sender: InMemoryEmailSender
) -> None:
    user, other = await register(client), await register(client)
    await put_token(client, user, "dev-1")
    await put_token(client, user, "dev-2")
    await put_token(client, other, "other-dev")
    await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    resp = await client.post(
        "/v1/auth/password-reset/confirm",
        json={
            "email": user.email,
            "code": email_sender.outbox[-1].code,
            "new_password": "brand new password",
        },
    )
    assert resp.status_code == 204
    assert await token_rows(engine, user) == []
    assert len(await token_rows(engine, other)) == 1
