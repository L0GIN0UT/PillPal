"""The 202 of register, verify-email/resend and password-reset/request does not depend on whether
the address has an account: the request only looks the address up and hands a job to the
background; code rows and mail come after the response (``app.services.auth_mail_job``).

No wall-clock assertions: the tests check that both paths take the same steps."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
import structlog
from httpx import AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.db.models import EmailCode
from app.email import InMemoryEmailSender
from app.services.auth import AuthService
from app.services.auth_mail_job import MailJob, MailRunner
from tests.helpers import DEFAULT_PASSWORD, last_code, outbox, register, register_unverified


@pytest.fixture
def jobs(monkeypatch: pytest.MonkeyPatch) -> list[MailJob]:
    """Capture the jobs instead of running them: what the request itself did is then visible."""
    seen: list[MailJob] = []

    async def record(self: MailRunner, job: MailJob) -> None:
        seen.append(job)

    monkeypatch.setattr(MailRunner, "run", record)
    return seen


async def _code_rows(engine: AsyncEngine) -> int:
    async with AsyncSession(engine) as session:
        return int(await session.scalar(select(func.count()).select_from(EmailCode)) or 0)


def _unknown() -> str:
    return f"nobody-{uuid.uuid4().hex[:8]}@example.com"


def _register_body(email: str) -> dict[str, Any]:
    return {
        "email": email,
        "password": DEFAULT_PASSWORD,
        "region": "ru",
        "timezone": "Europe/Samara",
    }


async def test_request_does_no_code_work_and_no_send(
    client: AsyncClient, engine: AsyncEngine, jobs: list[MailJob]
) -> None:
    email = await register_unverified(client)
    jobs.clear()
    rows_before = await _code_rows(engine)
    outbox_before = len(outbox(client))

    resp = await client.post("/v1/auth/password-reset/request", json={"email": email})

    assert resp.status_code == 202
    assert [(j.kind, j.purpose) for j in jobs] == [("code", "password_reset")]
    assert await _code_rows(engine) == rows_before  # nothing issued in the request
    assert len(outbox(client)) == outbox_before  # nothing sent in the request


@pytest.mark.parametrize(
    ("path", "body"),
    [
        ("/v1/auth/password-reset/request", lambda e: {"email": e}),
        ("/v1/auth/verify-email/resend", lambda e: {"email": e}),
        ("/v1/auth/register", _register_body),
    ],
)
async def test_known_and_unknown_address_take_the_same_steps(
    client: AsyncClient, jobs: list[MailJob], path: str, body: Any
) -> None:
    known = await register_unverified(client)
    jobs.clear()  # the registration above queued its own job

    first = await client.post(path, json=body(known))
    second = await client.post(path, json=body(_unknown()))

    assert first.status_code == second.status_code == 202
    assert first.json() == second.json()
    assert len(jobs) == 2  # one job per request, whatever the address
    # The same kind of job for both, except register, where the known address gets a notice and
    # the new one a code: the request cannot tell more than the (identical) 202 anyway.
    if path != "/v1/auth/register":
        assert (jobs[0].kind, jobs[0].purpose) == (jobs[1].kind, jobs[1].purpose)
    assert jobs[0].user_id != jobs[1].user_id


async def test_unknown_address_job_carries_a_random_id_not_the_address(
    client: AsyncClient, jobs: list[MailJob]
) -> None:
    await client.post("/v1/auth/password-reset/request", json={"email": _unknown()})

    (job,) = jobs
    assert isinstance(job.user_id, uuid.UUID)
    assert set(vars(job)) == {"kind", "user_id", "purpose"}  # no address, no code


async def test_worker_step_sends_the_reset_code_to_a_known_address(
    client: AsyncClient,
) -> None:
    user = await register(client)

    resp = await client.post("/v1/auth/password-reset/request", json={"email": user.email})

    assert resp.status_code == 202
    assert len(last_code(client, user.email, "password_reset")) == 6


async def test_unknown_address_sends_nothing_and_writes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    before = len(outbox(client))
    rows = await _code_rows(engine)

    for path in ("/v1/auth/password-reset/request", "/v1/auth/verify-email/resend"):
        assert (await client.post(path, json={"email": _unknown()})).status_code == 202

    assert len(outbox(client)) == before
    assert await _code_rows(engine) == rows


async def test_resend_mails_a_new_code_only_to_an_unverified_account(
    client: AsyncClient,
) -> None:
    unverified_email = await register_unverified(client)
    verified = await register(client)
    mails = len(outbox(client))

    await client.post("/v1/auth/verify-email/resend", json={"email": verified.email})
    assert len(outbox(client)) == mails  # decided after the response; same 202

    await client.post("/v1/auth/verify-email/resend", json={"email": unverified_email})
    assert len(outbox(client)) == mails + 1


async def test_register_known_address_mails_the_notice_after_the_response(
    client: AsyncClient, jobs: list[MailJob]
) -> None:
    known = await register_unverified(client)
    jobs.clear()

    resp = await client.post("/v1/auth/register", json=_register_body(known))

    assert resp.status_code == 202
    assert [j.kind for j in jobs] == ["known_address_notice"]


async def test_register_new_address_creates_the_account_and_defers_the_code(
    client: AsyncClient, engine: AsyncEngine, jobs: list[MailJob]
) -> None:
    resp = await client.post("/v1/auth/register", json=_register_body(_unknown()))

    assert resp.status_code == 202
    assert [(j.kind, j.purpose) for j in jobs] == [("code", "verify_email")]
    assert await _code_rows(engine) == 0  # the code row is the job's work


async def test_a_failing_job_is_logged_by_class_only_and_never_raises(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    secret_address = user.email

    async def boom(self: AuthService, job: MailJob) -> None:
        raise RuntimeError(f"provider rejected {secret_address}")

    monkeypatch.setattr(AuthService, "deliver_mail", boom)
    with structlog.testing.capture_logs() as logs:
        resp = await client.post("/v1/auth/password-reset/request", json={"email": secret_address})

    assert resp.status_code == 202  # the answer is unaffected
    (entry,) = [e for e in logs if e["event"] == "auth_mail_job_failed"]
    assert entry["exc_type"] == "RuntimeError"
    assert entry["purpose"] == "password_reset"
    assert secret_address not in str(logs)


async def test_a_failing_send_is_swallowed_in_the_job(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)

    async def down(self: InMemoryEmailSender, **_: Any) -> None:
        raise RuntimeError("smtp down")

    monkeypatch.setattr(InMemoryEmailSender, "send_code", down)
    with structlog.testing.capture_logs() as logs:
        resp = await client.post("/v1/auth/password-reset/request", json={"email": user.email})

    assert resp.status_code == 202
    assert [e["exc_type"] for e in logs if e["event"] == "email_send_failed"] == ["RuntimeError"]
