"""FcmSender against ``httpx.MockTransport`` (a provider is a true external)."""

from __future__ import annotations

import json
import logging
from datetime import timedelta
from urllib.parse import parse_qs

import httpx
import jwt
import pytest

from app.push.base import Outcome
from app.push.fcm import FcmSender
from tests.push.helpers import (
    FCM_TOKEN,
    NOW,
    Clock,
    Recorder,
    message,
    public_pem,
    rsa_private_pem,
    service_account_json,
)

OAUTH_URL = "https://oauth2.googleapis.com/token"
SEND_URL = "https://fcm.googleapis.com/v1/projects/example-project/messages:send"


def _responder(
    send_response: httpx.Response | None = None, oauth_response: httpx.Response | None = None
):  # type: ignore[no-untyped-def]
    def respond(request: httpx.Request) -> httpx.Response:
        if str(request.url) == OAUTH_URL:
            return oauth_response or httpx.Response(
                200, json={"access_token": "ya29.token-1", "expires_in": 3600}
            )
        return send_response or httpx.Response(200, json={"name": "projects/p/messages/1"})

    return respond


def _sender(recorder: Recorder, clock: Clock | None = None) -> FcmSender:
    return FcmSender(
        project_id="example-project",
        service_account_json=service_account_json(),
        client=recorder.client(),
        clock=clock or Clock(),
    )


async def test_oauth_exchange_uses_the_hard_coded_token_url_and_a_signed_assertion() -> None:
    recorder = Recorder(_responder())
    result = await _sender(recorder).send(message("fcm", FCM_TOKEN))
    assert result.outcome is Outcome.OK
    oauth = recorder.requests[0]
    # The key file names another token_uri; it must be ignored (an exfiltration vector).
    assert str(oauth.url) == OAUTH_URL
    form = parse_qs(oauth.content.decode())
    assert form["grant_type"] == ["urn:ietf:params:oauth:grant-type:jwt-bearer"]
    claims = jwt.decode(
        form["assertion"][0],
        public_pem(rsa_private_pem()),
        algorithms=["RS256"],
        audience=OAUTH_URL,
        options={"verify_exp": False, "verify_iat": False},
    )
    assert claims["iss"] == "svc@example-project.iam.gserviceaccount.com"
    assert claims["scope"] == "https://www.googleapis.com/auth/firebase.messaging"
    assert claims["iat"] == int(NOW.timestamp())
    assert 0 < claims["exp"] - claims["iat"] <= 3600
    assert jwt.get_unverified_header(form["assertion"][0])["alg"] == "RS256"


async def test_send_request_shape() -> None:
    recorder = Recorder(_responder())
    await _sender(recorder).send(message("fcm", FCM_TOKEN))
    request = recorder.requests[1]
    assert request.method == "POST"
    assert str(request.url) == SEND_URL
    assert request.headers["authorization"] == "Bearer ya29.token-1"
    assert request.headers["content-type"] == "application/json"
    body = recorder.json_body()
    assert set(body) == {"message"}
    sent = body["message"]
    assert sent["token"] == FCM_TOKEN
    assert sent["data"]["t"] == "missed"
    assert sent["data"]["v"] == "1"
    assert all(isinstance(value, str) for value in sent["data"].values())
    assert set(sent["data"]) <= {"v", "t", "a", "p", "m", "g", "s"}
    assert sent["android"]["priority"] == "HIGH"
    assert sent["android"]["ttl"] == "7200s"
    # Alerts must not collapse each other (ADR 0008 §3), and no notification block: data only.
    assert "collapse_key" not in sent["android"]
    assert "notification" not in sent
    assert "notification" not in sent["android"]


async def test_access_token_is_cached_then_renewed_before_expiry() -> None:
    recorder = Recorder(_responder())
    clock = Clock()
    sender = _sender(recorder, clock)
    await sender.send(message("fcm", FCM_TOKEN))
    await sender.send(message("fcm", FCM_TOKEN))
    assert [str(r.url) for r in recorder.requests].count(OAUTH_URL) == 1
    clock.now = NOW + timedelta(seconds=3600 - 30)  # inside the safety margin
    await sender.send(message("fcm", FCM_TOKEN))
    assert [str(r.url) for r in recorder.requests].count(OAUTH_URL) == 2


@pytest.mark.parametrize(
    ("status", "body", "outcome", "code"),
    [
        (
            404,
            {
                "error": {
                    "code": 404,
                    "status": "NOT_FOUND",
                    "message": "x",
                    "details": [
                        {
                            "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                            "errorCode": "UNREGISTERED",
                        }
                    ],
                }
            },
            Outcome.INVALID_TOKEN,
            "UNREGISTERED",
        ),
        (
            400,
            {
                "error": {
                    "code": 400,
                    "status": "INVALID_ARGUMENT",
                    "message": "x",
                    "details": [
                        {
                            "@type": "type.googleapis.com/google.rpc.BadRequest",
                            "fieldViolations": [
                                {"field": "message.token", "description": "not valid"}
                            ],
                        }
                    ],
                }
            },
            Outcome.INVALID_TOKEN,
            "INVALID_ARGUMENT",
        ),
        (
            400,
            {
                "error": {
                    "code": 400,
                    "status": "INVALID_ARGUMENT",
                    "message": "bad data",
                    "details": [
                        {
                            "@type": "type.googleapis.com/google.rpc.BadRequest",
                            "fieldViolations": [
                                {"field": "message.data", "description": "too big"}
                            ],
                        }
                    ],
                }
            },
            Outcome.FATAL,
            "INVALID_ARGUMENT",
        ),
        (
            404,
            {"error": {"code": 404, "status": "NOT_FOUND", "message": "project"}},
            Outcome.FATAL,
            "NOT_FOUND",
        ),
        (
            403,
            {
                "error": {
                    "code": 403,
                    "status": "PERMISSION_DENIED",
                    "details": [{"errorCode": "SENDER_ID_MISMATCH"}],
                }
            },
            Outcome.FATAL,
            "SENDER_ID_MISMATCH",
        ),
        (
            401,
            {
                "error": {
                    "code": 401,
                    "status": "UNAUTHENTICATED",
                    "details": [{"errorCode": "THIRD_PARTY_AUTH_ERROR"}],
                }
            },
            Outcome.FATAL,
            "THIRD_PARTY_AUTH_ERROR",
        ),
        (
            429,
            {
                "error": {
                    "code": 429,
                    "status": "RESOURCE_EXHAUSTED",
                    "details": [{"errorCode": "QUOTA_EXCEEDED"}],
                }
            },
            Outcome.RETRY,
            "QUOTA_EXCEEDED",
        ),
        (503, {"error": {"code": 503, "status": "UNAVAILABLE"}}, Outcome.RETRY, "UNAVAILABLE"),
        (500, {"error": {"code": 500, "status": "INTERNAL"}}, Outcome.RETRY, "INTERNAL"),
    ],
)
async def test_error_mapping(
    status: int, body: dict[str, object], outcome: Outcome, code: str
) -> None:
    recorder = Recorder(_responder(httpx.Response(status, json=body)))
    result = await _sender(recorder).send(message("fcm", FCM_TOKEN))
    assert (result.outcome, result.code) == (outcome, code)


async def test_unparseable_error_bodies_fall_back_to_the_http_status() -> None:
    for status, outcome in ((502, Outcome.RETRY), (418, Outcome.FATAL)):
        recorder = Recorder(_responder(httpx.Response(status, text="<html>Aspirin</html>")))
        result = await _sender(recorder).send(message("fcm", FCM_TOKEN))
        assert (result.outcome, result.code) == (outcome, f"http_{status}")


async def test_error_text_from_the_provider_is_never_kept() -> None:
    body = {"error": {"status": "Aspirin 100 mg at 08:00", "message": FCM_TOKEN}}
    recorder = Recorder(_responder(httpx.Response(400, json=body)))
    result = await _sender(recorder).send(message("fcm", FCM_TOKEN))
    # Unusable provider text is dropped; the code falls back to the HTTP status.
    assert result.code == "http_400"


async def test_retry_after_is_honoured() -> None:
    response = httpx.Response(
        429, json={"error": {"status": "RESOURCE_EXHAUSTED"}}, headers={"Retry-After": "120"}
    )
    result = await _sender(Recorder(_responder(response))).send(message("fcm", FCM_TOKEN))
    assert result.outcome is Outcome.RETRY
    assert result.retry_after_seconds == 120


async def test_an_expired_oauth_token_is_dropped_and_the_send_retried() -> None:
    first = httpx.Response(401, json={"error": {"code": 401, "status": "UNAUTHENTICATED"}})
    recorder = Recorder(_responder(first))
    sender = _sender(recorder)
    result = await sender.send(message("fcm", FCM_TOKEN))
    assert result.outcome is Outcome.RETRY
    recorder.respond = _responder()
    assert (await sender.send(message("fcm", FCM_TOKEN))).outcome is Outcome.OK
    assert [str(r.url) for r in recorder.requests].count(OAUTH_URL) == 2


@pytest.mark.parametrize(
    ("oauth", "outcome"),
    [
        (httpx.Response(400, json={"error": "invalid_grant"}), Outcome.FATAL),
        (httpx.Response(401, json={"error": "invalid_client"}), Outcome.FATAL),
        (httpx.Response(503, text="down"), Outcome.RETRY),
        (httpx.Response(429, text="slow", headers={"Retry-After": "7"}), Outcome.RETRY),
        (httpx.Response(200, json={"unexpected": True}), Outcome.FATAL),
    ],
)
async def test_oauth_failures(oauth: httpx.Response, outcome: Outcome) -> None:
    recorder = Recorder(_responder(oauth_response=oauth))
    result = await _sender(recorder).send(message("fcm", FCM_TOKEN))
    assert result.outcome is outcome
    assert len(recorder.requests) == 1  # no send without an access token


async def test_transport_errors_are_retried_without_message_text(
    caplog: pytest.LogCaptureFixture, capsys: pytest.CaptureFixture[str]
) -> None:
    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(f"connect failed for {request.url} body={request.content!r}")

    caplog.set_level(logging.DEBUG)
    recorder = Recorder(boom)
    result = await _sender(recorder).send(message("fcm", FCM_TOKEN))
    assert (result.outcome, result.code) == (Outcome.RETRY, "transport_error")
    captured = capsys.readouterr().out + caplog.text + repr(result)
    assert FCM_TOKEN not in captured
    assert "connect failed" not in captured


async def test_message_repr_never_contains_the_token() -> None:
    assert FCM_TOKEN not in repr(message("fcm", FCM_TOKEN))


async def test_data_never_contains_free_text() -> None:
    recorder = Recorder(_responder())
    await _sender(recorder).send(message("fcm", FCM_TOKEN))
    assert "Aspirin" not in json.dumps(recorder.json_body())
