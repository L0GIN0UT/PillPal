"""The 202 of register, verify-email/resend and password-reset/request does not depend on whether
the address has an account: the request only validates and hashes (register) or looks the address
up (resend, reset), releases its session and hands a job to the background; accounts, code rows
and mail come after the response (``app.services.auth_mail_job``).

No wall-clock assertions: the tests check that both paths take the same steps."""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator, Callable
from typing import Any

import pytest
import pytest_asyncio
import structlog
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, create_async_engine

from app.db.models import EmailCode, User
from app.db.session import create_sessionmaker
from app.email import InMemoryEmailSender
from app.main import create_app
from app.services.auth import AuthService
from app.services.auth_mail_job import MailJob, MailRunner
from tests.conftest import make_settings
from tests.helpers import DEFAULT_PASSWORD, last_code, outbox, register, register_unverified


def capture_jobs(monkeypatch: pytest.MonkeyPatch) -> list[MailJob]:
    """From now on capture the jobs instead of running them: what the request itself did is then
    visible (accounts and mails made before the call stay)."""
    seen: list[MailJob] = []

    async def record(self: MailRunner, job: MailJob) -> None:
        seen.append(job)

    monkeypatch.setattr(MailRunner, "run", record)
    return seen


async def _count(engine: AsyncEngine, model: type) -> int:
    async with AsyncSession(engine) as session:
        return int(await session.scalar(select(func.count()).select_from(model)) or 0)


def _unknown() -> str:
    return f"nobody-{uuid.uuid4().hex[:8]}@example.com"


def _register_body(email: str) -> dict[str, Any]:
    return {
        "email": email,
        "password": DEFAULT_PASSWORD,
        "region": "ru",
        "timezone": "Europe/Samara",
    }


def _email_body(email: str) -> dict[str, Any]:
    return {"email": email}


async def test_request_does_no_code_work_and_no_send(
    client: AsyncClient, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    email = await register_unverified(client)
    jobs = capture_jobs(monkeypatch)
    rows_before = await _count(engine, EmailCode)
    outbox_before = len(outbox(client))

    resp = await client.post("/v1/auth/password-reset/request", json={"email": email})

    assert resp.status_code == 202
    assert [(j.kind, j.purpose) for j in jobs] == [("code", "password_reset")]
    assert await _count(engine, EmailCode) == rows_before  # nothing issued in the request
    assert len(outbox(client)) == outbox_before  # nothing sent in the request


@pytest.mark.parametrize(
    ("path", "body"),
    [
        ("/v1/auth/password-reset/request", _email_body),
        ("/v1/auth/verify-email/resend", _email_body),
        ("/v1/auth/register", _register_body),
    ],
)
async def test_known_and_unknown_address_take_the_same_steps(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
    path: str,
    body: Callable[[str], dict[str, Any]],
) -> None:
    known = await register_unverified(client)
    jobs = capture_jobs(monkeypatch)

    first = await client.post(path, json=body(known))
    second = await client.post(path, json=body(_unknown()))

    assert first.status_code == second.status_code == 202
    assert first.json() == second.json()
    assert len(jobs) == 2  # one job per request, whatever the address
    assert (jobs[0].kind, jobs[0].purpose) == (jobs[1].kind, jobs[1].purpose)
    assert jobs[0].user_id != jobs[1].user_id


async def test_register_request_creates_nothing_and_sends_nothing(
    client: AsyncClient, engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    jobs = capture_jobs(monkeypatch)
    users, mails = await _count(engine, User), len(outbox(client))

    resp = await client.post("/v1/auth/register", json=_register_body(_unknown()))

    assert resp.status_code == 202
    assert [j.kind for j in jobs] == ["register"]
    assert await _count(engine, User) == users  # the account is the job's work
    assert await _count(engine, EmailCode) == 0
    assert len(outbox(client)) == mails


async def test_job_repr_shows_no_address_or_password_hash(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    jobs = capture_jobs(monkeypatch)
    email = _unknown()
    await client.post("/v1/auth/register", json=_register_body(email))
    await client.post("/v1/auth/password-reset/request", json={"email": email})

    assert len(jobs) == 2
    for job in jobs:
        assert email not in repr(job)
        assert "argon2" not in repr(job)
        assert job.register is None or email not in repr(job.register)
        assert job.register is None or "argon2" not in repr(job.register)


async def test_register_job_creates_the_account_and_mails_the_code(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    email = await register_unverified(client)

    assert await _count(engine, User) == 1
    assert len(last_code(client, email)) == 6


async def test_register_job_for_a_known_address_mails_the_notice(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    email = await register_unverified(client)
    await register_unverified(client, email)

    assert await _count(engine, User) == 1
    assert [m.purpose for m in outbox(client) if m.to == email] == [
        "verify_email",
        "account_exists",
    ]


async def test_unknown_address_job_carries_a_random_id_and_no_payload(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    jobs = capture_jobs(monkeypatch)

    await client.post("/v1/auth/password-reset/request", json={"email": _unknown()})

    (job,) = jobs
    assert isinstance(job.user_id, uuid.UUID)
    assert job.register is None


async def test_job_sends_the_reset_code_to_a_known_address(client: AsyncClient) -> None:
    user = await register(client)

    resp = await client.post("/v1/auth/password-reset/request", json={"email": user.email})

    assert resp.status_code == 202
    assert len(last_code(client, user.email, "password_reset")) == 6


async def test_unknown_address_sends_nothing_and_writes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    before = len(outbox(client))
    rows = await _count(engine, EmailCode)

    for path in ("/v1/auth/password-reset/request", "/v1/auth/verify-email/resend"):
        assert (await client.post(path, json={"email": _unknown()})).status_code == 202

    assert len(outbox(client)) == before
    assert await _count(engine, EmailCode) == rows


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


# -- the request's session is released before the job takes its own -------------------------
# FastAPI closes a yield dependency only after background tasks: a request that kept its
# connection would hold one while the job asks for a second.


async def _tiny_pool_client(pool_size: int) -> AsyncIterator[AsyncClient]:
    settings = make_settings()
    app = create_app(settings, email_sender=InMemoryEmailSender())
    async with app.router.lifespan_context(app):
        small = create_async_engine(
            settings.database_url, pool_size=pool_size, max_overflow=0, pool_timeout=1
        )
        app.state.sessionmaker = create_sessionmaker(small)
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        try:
            async with AsyncClient(transport=transport, base_url="http://test") as api:
                yield api
        finally:
            await small.dispose()


@pytest_asyncio.fixture
async def pool_of_one(client: AsyncClient) -> AsyncIterator[AsyncClient]:
    async for api in _tiny_pool_client(1):
        yield api


@pytest_asyncio.fixture
async def pool_of_two(client: AsyncClient) -> AsyncIterator[AsyncClient]:
    async for api in _tiny_pool_client(2):
        yield api


async def test_each_endpoint_works_with_a_single_pooled_connection(
    pool_of_one: AsyncClient,
) -> None:
    api = pool_of_one
    email = await register_unverified(api)  # the job creates the account and mails the code
    assert len(last_code(api, email)) == 6

    await api.post("/v1/auth/verify-email/resend", json={"email": email})
    assert [m.purpose for m in outbox(api) if m.to == email] == ["verify_email"] * 2

    verified = await api.post(
        "/v1/auth/verify-email", json={"email": email, "code": last_code(api, email)}
    )
    assert verified.status_code == 200
    await api.post("/v1/auth/password-reset/request", json={"email": email})
    assert len(last_code(api, email, "password_reset")) == 6


async def test_two_concurrent_requests_both_succeed_with_two_connections(
    pool_of_two: AsyncClient,
) -> None:
    api = pool_of_two
    emails = [await register_unverified(api) for _ in range(2)]

    answers = await asyncio.gather(
        *(api.post("/v1/auth/password-reset/request", json={"email": e}) for e in emails)
    )

    assert [a.status_code for a in answers] == [202, 202]
    for email in emails:
        assert len(last_code(api, email, "password_reset")) == 6


def test_sentry_scrubs_the_register_payload_keys() -> None:
    from app.observability import SENTRY_SECRET_KEYS

    assert {"password_hash", "email"} <= SENTRY_SECRET_KEYS
