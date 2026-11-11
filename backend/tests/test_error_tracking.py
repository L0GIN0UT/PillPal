"""Backend error tracking (milestone 5.13): off without a DSN, and what leaves is scrubbed.

No database or Redis: the SDK runs for real and only its transport is replaced by one that keeps
the serialized events, so the tests read exactly what would have been sent.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import httpx
import pytest
import sentry_sdk
from fastapi import FastAPI, Request
from pydantic import ValidationError
from sentry_sdk.transport import Transport

from app.error_tracking import init_error_tracking
from app.main import create_app
from app.observability import FILTERED
from app.worker import on_startup
from tests.conftest import make_settings

DSN = "https://public@o0.ingest.invalid/1"
MEDICATION_NAME = "Парацетамол-секрет"
NOTE = "заметка-приём-секрет"
EMAIL = "patient.zero@example.com"
PASSWORD_HASH = "$argon2id$v=19$m=1024,t=1,p=1$c2FsdA$aGFzaA"
CODE = "482913"
QUERY_SECRET = "q-secret-needle"
BODY_SECRET = "body-secret-needle"


class CapturingTransport(Transport):
    def __init__(self, options: dict[str, Any] | None = None) -> None:
        super().__init__(options)
        self.payloads: list[dict[str, Any]] = []

    def capture_envelope(self, envelope: Any) -> None:
        for item in envelope.items:
            if item.headers.get("type") in ("event", "transaction"):
                self.payloads.append(json.loads(item.payload.get_bytes()))

    @property
    def raw(self) -> str:
        return json.dumps(self.payloads, ensure_ascii=False)


@pytest.fixture(autouse=True)
def _no_client_left_behind() -> Iterator[None]:
    yield
    sentry_sdk.get_global_scope().set_client(None)


def _enabled(transport: CapturingTransport, **overrides: object) -> bool:
    return init_error_tracking(make_settings(sentry_dsn=DSN, **overrides), transport=transport)


def test_nothing_is_initialized_without_a_dsn() -> None:
    assert init_error_tracking(make_settings()) is False
    assert not sentry_sdk.get_client().is_active()


@pytest.mark.parametrize("blank", ["", "   "])
def test_a_blank_dsn_means_no_error_tracking(blank: str) -> None:
    assert make_settings(sentry_dsn=blank).sentry_dsn is None


def test_the_dsn_is_not_echoed_in_a_settings_error() -> None:
    with pytest.raises(ValidationError) as caught:
        make_settings(sentry_dsn="not-a-dsn-secret-xyz")
    assert "secret-xyz" not in str(caught.value)


def test_sdk_options_are_privacy_safe() -> None:
    transport = CapturingTransport()
    assert _enabled(transport, environment="staging", sentry_release="abc123") is True
    options = sentry_sdk.get_client().options
    assert options["send_default_pii"] is False
    assert options["include_local_variables"] is False
    assert options["max_request_body_size"] == "never"
    assert options["max_breadcrumbs"] == 0
    assert options["traces_sample_rate"] == 0
    assert options["environment"] == "staging"
    assert options["release"] == "abc123"
    assert options["before_send"] is not None
    assert options["before_send_transaction"] is not None


def test_traces_sample_rate_comes_from_settings_and_is_bounded() -> None:
    _enabled(CapturingTransport(), sentry_traces_sample_rate=0.25)
    assert sentry_sdk.get_client().options["traces_sample_rate"] == 0.25
    with pytest.raises(ValidationError):
        make_settings(sentry_traces_sample_rate=1.5)


def test_secrets_in_the_event_are_scrubbed_and_frame_variables_are_not_sent() -> None:
    transport = CapturingTransport()
    _enabled(transport)

    def failing_job() -> None:
        medication_name = MEDICATION_NAME
        note = NOTE
        email = EMAIL
        password_hash = PASSWORD_HASH
        code = CODE
        raise RuntimeError(f"failed ({len(medication_name + note + email + password_hash + code)})")

    sentry_sdk.set_context(
        "job",
        {
            "name": MEDICATION_NAME,
            "email": EMAIL,
            "password_hash": PASSWORD_HASH,
            "note": NOTE,
            "attempt": 3,
        },
    )
    try:
        failing_job()
    except RuntimeError as exc:
        sentry_sdk.capture_exception(exc)

    assert len(transport.payloads) == 1
    event = transport.payloads[0]
    for secret in (MEDICATION_NAME, EMAIL, PASSWORD_HASH, NOTE, CODE):
        assert secret not in transport.raw
    assert event["contexts"]["job"]["email"] == FILTERED
    assert event["contexts"]["job"]["password_hash"] == FILTERED
    assert event["contexts"]["job"]["attempt"] == 3
    assert "vars" not in json.dumps(event["exception"])


async def test_no_request_body_query_string_or_credentials_are_captured() -> None:
    transport = CapturingTransport()
    _enabled(transport)
    app = FastAPI()

    @app.post("/boom/{item_id}")
    async def boom(item_id: str, request: Request) -> None:
        await request.json()
        raise RuntimeError("handler failed")

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app, raise_app_exceptions=False),
        base_url="http://testserver",
    ) as client:
        response = await client.post(
            f"/boom/42?token={QUERY_SECRET}&q={QUERY_SECRET}",
            json={"medication_name": MEDICATION_NAME, "note": BODY_SECRET, "code": CODE},
            headers={"Authorization": "Bearer bearer-secret-needle"},
        )

    assert response.status_code == 500
    assert len(transport.payloads) == 1
    request = transport.payloads[0]["request"]
    assert "data" not in request
    assert not request.get("query_string")
    for secret in (QUERY_SECRET, MEDICATION_NAME, BODY_SECRET, CODE, "bearer-secret-needle"):
        assert secret not in transport.raw


def test_the_api_initializes_error_tracking_only_with_a_dsn() -> None:
    create_app(make_settings())
    assert not sentry_sdk.get_client().is_active()
    create_app(make_settings(sentry_dsn=DSN))
    assert sentry_sdk.get_client().is_active()


async def test_the_worker_initializes_error_tracking_only_with_a_dsn() -> None:
    ctx: dict[str, Any] = {"settings": make_settings(), "senders": {}, "maker": object()}
    await on_startup(ctx)
    assert not sentry_sdk.get_client().is_active()
    ctx = {"settings": make_settings(sentry_dsn=DSN), "senders": {}, "maker": object()}
    await on_startup(ctx)
    assert sentry_sdk.get_client().is_active()


# --- exception text, unhandled errors, tracing, hosting -------------------------------------------

NEEDLE = "needle-medication-5mg"


def test_an_exception_message_never_leaves_the_process() -> None:
    transport = CapturingTransport()
    _enabled(transport)
    try:
        raise RuntimeError(f"cannot store {NEEDLE}")
    except RuntimeError as exc:
        sentry_sdk.capture_exception(exc)
    sentry_sdk.capture_message(f"message {NEEDLE}")

    assert len(transport.payloads) == 2
    assert NEEDLE not in transport.raw
    exception = transport.payloads[0]["exception"]["values"][0]
    assert exception["type"] == "RuntimeError"
    assert exception["stacktrace"]["frames"]


async def test_an_unhandled_route_error_is_reported_scrubbed_through_create_app() -> None:
    transport = CapturingTransport()
    settings = make_settings(sentry_dsn=DSN)
    app = create_app(settings)
    # create_app started the SDK with the real transport; swap in the capturing one.
    init_error_tracking(settings, transport=transport)

    @app.post("/v1/boom")
    async def boom(request: Request) -> None:
        await request.json()
        raise RuntimeError(f"cannot store {NEEDLE}")

    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=app), base_url="http://testserver"
    ) as client:
        response = await client.post(
            f"/v1/boom?q={NEEDLE}",
            json={"medication_name": NEEDLE},
            headers={"X-Custom": NEEDLE, "Authorization": "Bearer secret-token-needle"},
        )

    assert response.status_code == 500
    assert response.json()["error"]["code"] == "internal_error"
    assert len(transport.payloads) == 1
    assert NEEDLE not in transport.raw
    assert "secret-token-needle" not in transport.raw
    assert transport.payloads[0]["exception"]["values"][0]["type"] == "RuntimeError"


async def test_no_trace_headers_reach_outgoing_requests_and_spans_are_dropped() -> None:
    transport = CapturingTransport()
    _enabled(transport, sentry_traces_sample_rate=1.0)
    seen: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        with sentry_sdk.start_transaction(name="job"):
            await client.post(f"https://push.example.test/send/{NEEDLE}", json={})

    assert len(seen) == 1
    assert "sentry-trace" not in seen[0].headers
    assert "baggage" not in seen[0].headers
    sentry_sdk.get_client().flush()
    assert transport.payloads, "the transaction should have been captured"
    assert all("spans" not in payload for payload in transport.payloads)
    assert NEEDLE not in transport.raw


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_refuse_tracing(environment: str) -> None:
    with pytest.raises(ValidationError, match="SENTRY_TRACES_SAMPLE_RATE"):
        make_settings(environment=environment, sentry_traces_sample_rate=0.1)


def test_the_russian_region_refuses_the_hosted_sentry() -> None:
    for dsn in ("https://k@o1.ingest.sentry.io/1", "https://k@sentry.io/1"):
        with pytest.raises(ValidationError, match="REGION=ru"):
            make_settings(region="ru", sentry_dsn=dsn)
    make_settings(region="ru", sentry_dsn="https://k@sentry.ru.example/1")
    make_settings(region="eu", sentry_dsn="https://k@o1.ingest.de.sentry.io/1")


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_require_https_for_the_dsn(environment: str) -> None:
    with pytest.raises(ValidationError, match="https"):
        make_settings(environment=environment, sentry_dsn="http://k@sentry.ru.example/1")


def test_a_plain_http_dsn_is_fine_in_dev_and_test() -> None:
    for environment in ("dev", "test"):
        make_settings(environment=environment, sentry_dsn="http://k@localhost:9000/1")


def test_the_dsn_may_come_from_a_docker_secret_file(tmp_path: Any) -> None:
    secret = tmp_path / "sentry_dsn"
    secret.write_text(DSN + chr(10), encoding="utf-8")
    settings = make_settings(sentry_dsn_file=str(secret))
    assert settings.sentry_dsn is not None
    assert settings.sentry_dsn.get_secret_value() == DSN
    with pytest.raises(ValidationError, match="SENTRY_DSN and SENTRY_DSN_FILE"):
        make_settings(sentry_dsn=DSN, sentry_dsn_file=str(secret))


def test_request_headers_are_reduced_to_an_allowlist() -> None:
    transport = CapturingTransport()
    _enabled(transport)
    with sentry_sdk.new_scope() as scope:
        scope.add_event_processor(
            lambda event, hint: {
                **event,
                "request": {
                    "url": "http://h/x?q=1",
                    "headers": {"Content-Type": "a/b", "X-Forwarded-For": "203.0.113.7"},
                },
            }
        )
        sentry_sdk.capture_message("x")
    request = transport.payloads[0]["request"]
    assert request["url"] == "http://h/x"
    assert request["headers"] == {"Content-Type": "a/b"}
