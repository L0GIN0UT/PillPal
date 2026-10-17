"""RuStoreSender against ``httpx.MockTransport``."""

from __future__ import annotations

import logging

import httpx
import pytest

from app.push.base import Outcome
from app.push.rustore import RuStoreSender
from tests.push.helpers import RUSTORE_TOKEN, Recorder, message

SERVICE_TOKEN = "service-token-xyz"
URL = "https://vkpns.rustore.ru/v1/projects/proj-1/messages:send"


def _ok(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, json={"message": {}})


def _sender(recorder: Recorder) -> RuStoreSender:
    return RuStoreSender(project_id="proj-1", service_token=SERVICE_TOKEN, client=recorder.client())


async def test_request_shape() -> None:
    recorder = Recorder(_ok)
    result = await _sender(recorder).send(message("rustore", RUSTORE_TOKEN))
    assert result.outcome is Outcome.OK
    request = recorder.requests[0]
    assert (request.method, str(request.url)) == ("POST", URL)
    assert request.headers["authorization"] == f"Bearer {SERVICE_TOKEN}"
    body = recorder.json_body()
    # Only fields the API documents: no priority, no collapse key (ADR 0008 §5).
    assert set(body) == {"message"}
    sent = body["message"]
    assert set(sent) == {"token", "data", "android"}
    assert sent["token"] == RUSTORE_TOKEN
    assert sent["android"] == {"ttl": "7200s"}
    assert sent["data"]["t"] == "missed"
    assert all(isinstance(value, str) for value in sent["data"].values())


@pytest.mark.parametrize(
    ("status", "body", "outcome", "code"),
    [
        (
            404,
            {"code": 404, "status": "NOT_FOUND", "message": "user push token is incorrect"},
            Outcome.INVALID_TOKEN,
            "NOT_FOUND",
        ),
        (
            400,
            {
                "code": 400,
                "status": "INVALID_ARGUMENT",
                "message": "The registration token is not a valid token",
            },
            Outcome.INVALID_TOKEN,
            "INVALID_ARGUMENT",
        ),
        (
            400,
            {"code": 400, "status": "INVALID_ARGUMENT", "message": "ttl is malformed"},
            Outcome.FATAL,
            "INVALID_ARGUMENT",
        ),
        (
            403,
            {"code": 403, "status": "PERMISSION_DENIED", "message": "service key is incorrect"},
            Outcome.FATAL,
            "PERMISSION_DENIED",
        ),
        (
            401,
            {"code": 401, "status": "UNAUTHENTICATED", "message": "x"},
            Outcome.FATAL,
            "UNAUTHENTICATED",
        ),
        (
            429,
            {"code": 429, "status": "TOO_MANY_REQUESTS", "message": "x"},
            Outcome.RETRY,
            "TOO_MANY_REQUESTS",
        ),
        (500, {"code": 500, "status": "INTERNAL", "message": "x"}, Outcome.RETRY, "INTERNAL"),
    ],
)
async def test_error_mapping(
    status: int, body: dict[str, object], outcome: Outcome, code: str
) -> None:
    recorder = Recorder(lambda request: httpx.Response(status, json=body))
    result = await _sender(recorder).send(message("rustore", RUSTORE_TOKEN))
    assert (result.outcome, result.code) == (outcome, code)


async def test_bare_http_statuses_without_a_body() -> None:
    for status, outcome in ((403, Outcome.FATAL), (401, Outcome.FATAL), (503, Outcome.RETRY)):
        recorder = Recorder(lambda request, s=status: httpx.Response(s, text="nope"))
        result = await _sender(recorder).send(message("rustore", RUSTORE_TOKEN))
        assert (result.outcome, result.code) == (outcome, f"http_{status}")


async def test_retry_after_is_honoured_when_present() -> None:
    recorder = Recorder(
        lambda request: httpx.Response(
            429, json={"status": "TOO_MANY_REQUESTS"}, headers={"Retry-After": "45"}
        )
    )
    result = await _sender(recorder).send(message("rustore", RUSTORE_TOKEN))
    assert result.retry_after_seconds == 45


async def test_provider_message_text_is_never_kept() -> None:
    recorder = Recorder(
        lambda request: httpx.Response(
            400, json={"status": "Take Aspirin 100 mg", "message": RUSTORE_TOKEN}
        )
    )
    result = await _sender(recorder).send(message("rustore", RUSTORE_TOKEN))
    assert result.code == "http_400"


async def test_transport_error_is_retried_and_leaks_nothing(
    caplog: pytest.LogCaptureFixture, capsys: pytest.CaptureFixture[str]
) -> None:
    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout(f"timed out: {SERVICE_TOKEN} {RUSTORE_TOKEN}")

    caplog.set_level(logging.DEBUG)
    result = await _sender(Recorder(boom)).send(message("rustore", RUSTORE_TOKEN))
    assert (result.outcome, result.code) == (Outcome.RETRY, "transport_error")
    seen = capsys.readouterr().out + caplog.text + repr(result)
    assert SERVICE_TOKEN not in seen
    assert RUSTORE_TOKEN not in seen
    assert "timed out" not in seen
