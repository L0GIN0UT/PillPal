"""Smaller contracts: e-mail sender hygiene, rehashing, lazy ASGI app, LWW monotonicity."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient

import app.main as main_module
from app.email import LoggingEmailSender, mask_email
from app.main import create_app
from app.security import PasswordHasher
from tests.conftest import make_settings
from tests.helpers import DEFAULT_PASSWORD, create_medication, register
from tests.test_platform import _json_lines


async def test_logging_email_sender_masks_address_and_hides_code(
    capsys: pytest.CaptureFixture[str],
) -> None:
    capsys.readouterr()
    await LoggingEmailSender().send_code(
        to="someone@example.com", purpose="verify_email", code="123456"
    )
    out = capsys.readouterr().out
    assert "someone@example.com" not in out
    assert "123456" not in out
    assert any(e.get("to") == "s***@example.com" for e in _json_lines(out))

    await LoggingEmailSender(log_codes=True).send_code(
        to="someone@example.com", purpose="verify_email", code="654321"
    )
    assert "654321" in capsys.readouterr().out
    assert mask_email("broken") == "***"


class _FailingSender:
    async def send_code(self, *, to: str, purpose: str, code: str) -> None:
        raise ConnectionError("smtp down")


async def test_mail_failure_does_not_fail_registration(
    migrated_db: str, capsys: pytest.CaptureFixture[str]
) -> None:
    app = create_app(make_settings(), email_sender=_FailingSender())  # type: ignore[arg-type]
    async with (
        app.router.lifespan_context(app),
        AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c,
    ):
        resp = await c.post(
            "/v1/auth/register",
            json={
                "email": f"m-{uuid.uuid4().hex[:8]}@example.com",
                "password": DEFAULT_PASSWORD,
                "region": "ru",
            },
        )
    assert resp.status_code == 201
    assert any(e.get("event") == "email_send_failed" for e in _json_lines(capsys.readouterr().out))


async def test_password_rehash_on_parameter_change() -> None:
    weak = PasswordHasher(make_settings())
    strong = PasswordHasher(make_settings(password_hash_time_cost=2))
    stored = await weak.hash("pw-123456789")
    assert strong.needs_rehash(stored)
    assert await strong.verify(stored, "pw-123456789")
    assert not await strong.verify(None, "pw-123456789")
    assert not await strong.verify("not-a-hash", "pw-123456789")


async def test_login_upgrades_outdated_hash(migrated_db: str, client: AsyncClient) -> None:
    user = await register(client)
    app = create_app(make_settings(password_hash_time_cost=2), email_sender=None)
    async with (
        app.router.lifespan_context(app),
        AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c,
    ):
        resp = await c.post("/v1/auth/login", json={"email": user.email, "password": user.password})
        assert resp.status_code == 200
    # The upgraded hash still verifies through the original app.
    again = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": user.password}
    )
    assert again.status_code == 200


def test_asgi_app_is_built_lazily_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REGION", "eu")
    monkeypatch.setenv("JWT_SECRET", "z" * 40)
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@localhost/x")
    main_module._default_app.cache_clear()
    try:
        asgi = main_module.app
        assert asgi.state.settings.region == "eu"
    finally:
        main_module._default_app.cache_clear()
    with pytest.raises(AttributeError):
        _ = main_module.nope  # type: ignore[attr-defined]


async def test_control_characters_are_rejected(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.post(
        f"/v1/profiles/{user.self_profile_id}/medications",
        json={"id": str(uuid.uuid4()), "name": "Bad\x00name"},
        headers=user.headers,
    )
    assert resp.status_code == 422


async def test_rest_write_beats_earlier_sync_even_with_fast_device_clock(
    client: AsyncClient,
) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    ahead = datetime.now(UTC) + timedelta(hours=1)  # device clock runs fast

    def mutation(name: str, at: datetime) -> dict[str, object]:
        return {
            "entity": "medication",
            "op": "upsert",
            "id": med["id"],
            "data": {"profile_id": user.self_profile_id, "name": name},
            "client_updated_at": at.isoformat(),
        }

    pushed = await client.post(
        "/v1/sync/push", json={"mutations": [mutation("Sync", ahead)]}, headers=user.device("d")
    )
    assert pushed.json()["results"][0]["status"] == "applied"
    patched = await client.patch(
        f"/v1/medications/{med['id']}", json={"name": "Rest"}, headers=user.headers
    )
    assert patched.json()["name"] == "Rest"
    # The REST write got a key after the sync write, so the replay stays stale.
    replay = await client.post(
        "/v1/sync/push", json={"mutations": [mutation("Sync", ahead)]}, headers=user.device("d")
    )
    assert replay.json()["results"][0]["status"] == "ignored_stale"
