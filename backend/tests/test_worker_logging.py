"""A failing job logs its exception type and frames, never text that may hold data
(ADR 0007 §6); provider connection errors never log device tokens (ADR 0008 §4)."""

from __future__ import annotations

import httpx
import pytest
from httpx import AsyncClient
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine

from app import worker
from app.config import Settings
from app.push.apns import ApnsSender
from tests.conftest import FakeClock
from tests.helpers import register
from tests.push.helpers import ec_private_pem
from tests.push_helpers import APNS_TOKEN, put_token
from tests.push_outbox_helpers import fake_senders, insert_outbox, outbox_rows
from tests.worker_helpers import run_burst

SECRET = "Aspirin-100mg-secret-token-xyz"  # synthetic: stands for data an error might embed


async def test_a_failing_job_logs_type_and_frames_only(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    client: AsyncClient,
    settings: Settings,
    now: FakeClock,
) -> None:
    async def explode(*args: object, **kwargs: object) -> None:
        # What a database error looks like: SQL, parameters (medical data) and a driver message.
        raise IntegrityError(
            "INSERT INTO medications (name) VALUES (%(name)s)",
            {"name": SECRET},
            Exception(f"duplicate key value {SECRET}"),
        )

    monkeypatch.setattr(worker, "deliver_pending", explode)
    result = await run_burst(settings, fake_senders(), now, "deliver_pushes")
    assert (result.jobs_complete, result.jobs_failed) == (0, 1)
    out = capsys.readouterr().out
    assert SECRET not in out
    assert "INSERT INTO" not in out
    assert "duplicate key" not in out
    assert '"event": "job_failed"' in out
    assert '"exc_type": "IntegrityError"' in out
    assert "app/worker.py" in out  # frames are there
    assert "deliver_pushes failed (IntegrityError)" in out  # what ARQ itself logs


async def test_a_failing_erase_job_is_sanitized_the_same_way(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    client: AsyncClient,
    settings: Settings,
    now: FakeClock,
) -> None:
    async def explode(*args: object, **kwargs: object) -> None:
        raise ValueError(f"bad input {SECRET}")

    monkeypatch.setattr(worker, "erase_expired_accounts", explode)
    monkeypatch.setattr(worker, "cleanup_retention", explode)
    result = await run_burst(
        settings, fake_senders(), now, "erase_expired_accounts", "cleanup_retention"
    )
    assert result.jobs_failed == 2
    out = capsys.readouterr().out
    assert SECRET not in out
    assert out.count('"event": "job_failed"') == 2


async def test_an_apns_connection_error_logs_no_device_token(
    capsys: pytest.CaptureFixture[str],
    client: AsyncClient,
    engine: AsyncEngine,
    settings: Settings,
    now: FakeClock,
) -> None:
    user = await register(client)
    await put_token(
        client, user, "ios", provider="apns", token=APNS_TOKEN, apns_environment="production"
    )
    await insert_outbox(engine, user, user.self_profile_id)

    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(f"All connection attempts failed: {request.url}")

    senders = fake_senders()
    apns = ApnsSender(
        team_id="ABCDE12345",
        key_id="KEY1234567",
        private_key=ec_private_pem(),
        topic="app.example.pillpal",
        client=httpx.AsyncClient(transport=httpx.MockTransport(refuse), http2=True),
        clock=now,
    )
    senders["apns"] = apns  # type: ignore[assignment]
    result = await run_burst(settings, senders, now, "deliver_pushes")
    assert (result.jobs_complete, result.jobs_failed) == (1, 0)
    out = capsys.readouterr().out
    assert APNS_TOKEN not in out
    assert "All connection attempts failed" not in out
    assert "/3/device/" not in out
    assert '"event": "push_transport_error"' in out
    assert '"exc_type": "ConnectError"' in out
    (row,) = await outbox_rows(engine)
    assert (row.status, row.attempts, row.last_error_code) == ("pending", 1, "transport_error")
    await apns.aclose()


async def test_delivery_logs_carry_ids_and_codes_not_tokens_or_payloads(
    capsys: pytest.CaptureFixture[str],
    client: AsyncClient,
    engine: AsyncEngine,
    settings: Settings,
    now: FakeClock,
) -> None:
    user = await register(client)
    await put_token(client, user, "dev-1", token="fcm-secret-token-value")
    row_id = await insert_outbox(engine, user, user.self_profile_id)
    senders = fake_senders()
    senders["fcm"].results = [senders["fcm"].retry("UNAVAILABLE")]
    await run_burst(settings, senders, now, "deliver_pushes")
    out = capsys.readouterr().out
    assert "fcm-secret-token-value" not in out
    assert user.self_profile_id not in out  # payload ids are not logged either
    assert f'"delivery_id": "{row_id}"' in out
    assert '"provider": "fcm"' in out
    assert '"outcome": "retry"' in out
    assert '"error_code": "UNAVAILABLE"' in out
