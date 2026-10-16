"""Small units of the deletion-grace feature: scrubbing, error details, settings, mail, tickets."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from pydantic import ValidationError
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncEngine

from app.email import InMemoryEmailSender, LoggingEmailSender
from app.errors import AppError
from app.observability import redact_sensitive, scrub_sentry_event
from app.services import account_deletion
from app.services.restore_tickets import RestoreTickets
from tests.conftest import make_settings
from tests.helpers import link_accounts, register
from tests.test_access import session_for


def test_sentry_events_lose_restore_tickets_and_other_bearer_secrets_at_any_depth() -> None:
    event: dict[str, Any] = {
        "request": {
            "data": {"restore_ticket": "TICKET-SECRET", "code": "123456", "keep": "ok"},
            "headers": {"Authorization": "Bearer ACCESS-SECRET"},
        },
        "extra": {"details": {"restore_ticket": "TICKET-SECRET"}},
        "breadcrumbs": {"values": [{"data": {"refresh_token": "REFRESH-SECRET"}}]},
        "exception": {"values": [{"stacktrace": {"frames": [{"vars": {"password": "pw"}}]}}]},
    }

    scrubbed = scrub_sentry_event(event, {})

    assert scrubbed is not None
    dumped = str(scrubbed)
    for secret in ("TICKET-SECRET", "ACCESS-SECRET", "REFRESH-SECRET", "123456", "'pw'"):
        assert secret not in dumped
    assert scrubbed["request"]["data"]["keep"] == "ok"
    assert scrubbed["request"]["data"]["restore_ticket"] == "[Filtered]"


def test_sentry_keeps_error_codes_but_scrubs_one_time_codes_in_bodies_and_frames() -> None:
    event: dict[str, Any] = {
        "request": {"data": {"code": "123456", "email": "x"}},
        "extra": {"error": {"code": "account_pending_deletion"}},
        "exception": {"values": [{"stacktrace": {"frames": [{"vars": {"code": "654321"}}]}}]},
    }

    scrubbed = scrub_sentry_event(event, {})

    assert scrubbed is not None
    assert scrubbed["extra"]["error"]["code"] == "account_pending_deletion"
    assert scrubbed["request"]["data"]["code"] == "[Filtered]"
    assert "654321" not in str(scrubbed)


def test_log_lines_redact_the_restore_ticket() -> None:
    out = redact_sensitive(None, "info", {"event": "x", "restore_ticket": "T"})
    assert out["restore_ticket"] == "[redacted]"


async def test_error_details_are_serialized_only_when_present() -> None:
    from app.errors import _app_error

    with_details = await _app_error(
        None,  # type: ignore[arg-type]
        AppError(403, "c", "m", details={"a": 1}),
    )
    without = await _app_error(None, AppError(403, "c", "m"))  # type: ignore[arg-type]
    assert b'"details":{"a":1}' in bytes(with_details.body)
    assert b"details" not in bytes(without.body)


@pytest.mark.parametrize(
    "overrides",
    [
        {"account_deletion_grace_days": 0},
        {"account_deletion_grace_days": 31},  # more than 152-FZ art. 21(5) allows
        {"account_erasure_job_interval_seconds": 30 * 24 * 3600},  # grace must outlast the job
        {"account_restore_ticket_ttl_seconds": 10},
        {"managed_archive_retention_days": 0},
        {"account_erasure_batch_size": 0},
    ],
)
def test_deletion_settings_are_validated(overrides: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        make_settings(**overrides)


def test_deletion_settings_have_the_documented_defaults() -> None:
    s = make_settings()
    assert (
        s.account_deletion_grace_days,
        s.account_erasure_job_interval_seconds,
        s.account_restore_ticket_ttl_seconds,
        s.managed_archive_retention_days,
    ) == (30, 3600, 600, 365)


async def test_notices_are_recorded_and_the_logging_sender_never_sees_the_address(
    capsys: pytest.CaptureFixture[str],
) -> None:
    sender = InMemoryEmailSender()
    when = datetime(2026, 11, 15, tzinfo=UTC)
    await sender.send_notice(
        to="x@example.com", user_id=uuid.uuid4(), kind="deletion_requested", erase_after=when
    )
    assert (sender.outbox[0].purpose, sender.outbox[0].erase_after) == ("deletion_requested", when)

    await LoggingEmailSender().send_notice(
        to="private@example.com", user_id=uuid.uuid4(), kind="account_restored"
    )
    assert "private@example.com" not in capsys.readouterr().out


async def test_tickets_fail_closed_without_redis() -> None:
    dead = Redis(host="localhost", port=1, socket_connect_timeout=0.2)
    tickets = RestoreTickets(dead, 600)
    try:
        for call in (tickets.issue(uuid.uuid4(), "c"), tickets.owner("t")):
            with pytest.raises(AppError) as exc:
                await call
            assert (exc.value.status_code, exc.value.code) == (503, "retry_later")
        await tickets.spend("t")  # never raises: the ticket dies by its TTL anyway
    finally:
        await dead.aclose()


async def test_owners_to_notify_of_a_restore_are_the_owners_of_the_grants_held(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    first, second, relative, stranger = [await register(client) for _ in range(4)]
    await link_accounts(client, first, relative, "viewer")
    await link_accounts(client, second, relative, "editor")
    async with session_for(engine) as session:
        owners = await account_deletion.owners_of_grants_held_by(session, uuid.UUID(relative.id))
        none = await account_deletion.owners_of_grants_held_by(session, uuid.UUID(stranger.id))
    assert owners == {uuid.UUID(first.id), uuid.UUID(second.id)}
    assert none == set()
    assert timedelta(0) == timedelta()
