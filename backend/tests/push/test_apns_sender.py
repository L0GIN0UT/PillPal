"""ApnsSender against ``httpx.MockTransport``."""

from __future__ import annotations

import json
import logging
import uuid
from datetime import timedelta

import httpx
import jwt
import pytest

from app.push.apns import ApnsSender
from app.push.base import Outcome
from tests.push.helpers import APNS_TOKEN, NOW, Clock, Recorder, ec_private_pem, message, public_pem

TOPIC = "app.example.pillpal"


def _ok(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200)


def _sender(recorder: Recorder, clock: Clock | None = None) -> ApnsSender:
    return ApnsSender(
        team_id="ABCDE12345",
        key_id="KEY1234567",
        private_key=ec_private_pem(),
        topic=TOPIC,
        client=recorder.client(http2=True),
        clock=clock or Clock(),
    )


async def test_request_shape_production() -> None:
    recorder = Recorder(_ok)
    result = await _sender(recorder).send(message("apns", APNS_TOKEN, environment="production"))
    assert result.outcome is Outcome.OK
    request = recorder.requests[0]
    assert request.method == "POST"
    assert str(request.url) == f"https://api.push.apple.com/3/device/{APNS_TOKEN}"
    headers = request.headers
    assert headers["apns-topic"] == TOPIC
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-priority"] == "10"
    assert headers["apns-expiration"] == str(int(NOW.timestamp()) + 7200)
    assert headers["apns-collapse-id"] == "11111111-1111-4111-8111-111111111111"
    assert str(uuid.UUID(headers["apns-id"])) == headers["apns-id"]
    assert headers["authorization"].startswith("bearer ")


async def test_sandbox_tokens_go_to_the_sandbox_host() -> None:
    recorder = Recorder(_ok)
    await _sender(recorder).send(message("apns", APNS_TOKEN, environment="sandbox"))
    assert recorder.requests[0].url.host == "api.sandbox.push.apple.com"


async def test_body_is_a_generic_alert_with_ids_only_and_no_medication() -> None:
    recorder = Recorder(_ok)
    await _sender(recorder).send(message("apns", APNS_TOKEN, environment="production"))
    body = recorder.json_body()
    assert body["aps"] == {
        "alert": {"loc-key": "relatives_alert_1"},
        "thread-id": "22222222-2222-4222-8222-222222222222",
        "mutable-content": 1,
    }
    # ADR 0008 §2: nothing uses the medication id without the notification extension.
    assert "m" not in body
    assert "33333333-3333-4333-8333-333333333333" not in json.dumps(body)
    assert body["t"] == "missed"
    assert body["a"] == "11111111-1111-4111-8111-111111111111"
    assert body["s"] == "u"
    assert set(body) <= {"aps", "v", "t", "a", "p", "g", "s"}
    # The key is neutral: Apple sees it.
    assert "missed" not in body["aps"]["alert"]["loc-key"]


async def test_link_notice_has_no_collapse_id_and_its_own_generic_key() -> None:
    recorder = Recorder(_ok)
    await _sender(recorder).send(
        message("apns", APNS_TOKEN, kind="link_accepted", environment="production")
    )
    assert recorder.json_body()["aps"]["alert"]["loc-key"] == "relatives_alert_3"
    # ``a`` is absent for link notices, so nothing is collapsed.
    assert "apns-collapse-id" not in recorder.requests[0].headers


async def test_each_attempt_has_its_own_apns_id() -> None:
    recorder = Recorder(_ok)
    sender = _sender(recorder)
    for _ in range(2):
        await sender.send(message("apns", APNS_TOKEN, environment="production"))
    assert recorder.requests[0].headers["apns-id"] != recorder.requests[1].headers["apns-id"]


async def test_provider_jwt_is_es256_and_cached_then_renewed() -> None:
    recorder = Recorder(_ok)
    clock = Clock()
    sender = _sender(recorder, clock)
    await sender.send(message("apns", APNS_TOKEN, environment="production"))
    await sender.send(message("apns", APNS_TOKEN, environment="production"))
    first = recorder.requests[0].headers["authorization"].split(" ", 1)[1]
    assert recorder.requests[1].headers["authorization"].split(" ", 1)[1] == first
    header = jwt.get_unverified_header(first)
    assert (header["alg"], header["kid"]) == ("ES256", "KEY1234567")
    claims = jwt.decode(
        first, public_pem(ec_private_pem()), algorithms=["ES256"], options={"verify_iat": False}
    )
    assert claims == {"iss": "ABCDE12345", "iat": int(NOW.timestamp())}
    # Apple wants a new token between every 20 and 60 minutes: renewed after 50.
    clock.now = NOW + timedelta(minutes=51)
    await sender.send(message("apns", APNS_TOKEN, environment="production"))
    assert recorder.requests[2].headers["authorization"].split(" ", 1)[1] != first


@pytest.mark.parametrize(
    ("status", "body", "outcome", "code"),
    [
        (
            410,
            {"reason": "Unregistered", "timestamp": 1760000000000},
            Outcome.INVALID_TOKEN,
            "Unregistered",
        ),
        (410, {"reason": "ExpiredToken"}, Outcome.INVALID_TOKEN, "ExpiredToken"),
        (400, {"reason": "BadDeviceToken"}, Outcome.INVALID_TOKEN, "BadDeviceToken"),
        (
            400,
            {"reason": "DeviceTokenNotForTopic"},
            Outcome.INVALID_TOKEN,
            "DeviceTokenNotForTopic",
        ),
        (403, {"reason": "ExpiredProviderToken"}, Outcome.RETRY, "ExpiredProviderToken"),
        (403, {"reason": "InvalidProviderToken"}, Outcome.FATAL, "InvalidProviderToken"),
        (403, {"reason": "Forbidden"}, Outcome.FATAL, "Forbidden"),
        (400, {"reason": "BadTopic"}, Outcome.FATAL, "BadTopic"),
        (400, {"reason": "TopicDisallowed"}, Outcome.FATAL, "TopicDisallowed"),
        (413, {"reason": "PayloadTooLarge"}, Outcome.FATAL, "PayloadTooLarge"),
        (429, {"reason": "TooManyRequests"}, Outcome.RETRY, "TooManyRequests"),
        (500, {"reason": "InternalServerError"}, Outcome.RETRY, "InternalServerError"),
        (503, {"reason": "ServiceUnavailable"}, Outcome.RETRY, "ServiceUnavailable"),
    ],
)
async def test_error_mapping(
    status: int, body: dict[str, object], outcome: Outcome, code: str
) -> None:
    recorder = Recorder(lambda request: httpx.Response(status, json=body))
    result = await _sender(recorder).send(message("apns", APNS_TOKEN, environment="production"))
    assert (result.outcome, result.code) == (outcome, code)


async def test_410_carries_the_instant_the_token_stopped_being_valid() -> None:
    recorder = Recorder(
        lambda request: httpx.Response(
            410, json={"reason": "Unregistered", "timestamp": 1760000000000}
        )
    )
    result = await _sender(recorder).send(message("apns", APNS_TOKEN, environment="production"))
    assert result.invalid_since is not None
    assert result.invalid_since.timestamp() == 1760000000


async def test_expired_provider_token_is_renewed_on_the_next_attempt() -> None:
    state = {"status": 403}

    def respond(request: httpx.Request) -> httpx.Response:
        if state["status"] == 403:
            return httpx.Response(403, json={"reason": "ExpiredProviderToken"})
        return httpx.Response(200)

    recorder = Recorder(respond)
    clock = Clock()
    sender = _sender(recorder, clock)
    await sender.send(message("apns", APNS_TOKEN, environment="production"))
    state["status"] = 200
    clock.now = NOW + timedelta(seconds=30)
    result = await sender.send(message("apns", APNS_TOKEN, environment="production"))
    assert result.outcome is Outcome.OK
    first, second = (r.headers["authorization"] for r in recorder.requests)
    assert first != second


async def test_retry_after_and_unknown_codes() -> None:
    recorder = Recorder(
        lambda request: httpx.Response(
            503, json={"reason": "Aspirin at 08:00"}, headers={"Retry-After": "30"}
        )
    )
    result = await _sender(recorder).send(message("apns", APNS_TOKEN, environment="production"))
    assert result.outcome is Outcome.RETRY
    assert result.retry_after_seconds == 30
    assert result.code == "http_503"


async def test_a_token_that_is_not_hex_never_reaches_the_url() -> None:
    recorder = Recorder(_ok)
    bad = message("apns", "../../v1/evil?x=", environment="production")
    result = await _sender(recorder).send(bad)
    assert recorder.requests == []
    assert result.outcome is Outcome.INVALID_TOKEN


async def test_missing_environment_is_a_configuration_error() -> None:
    recorder = Recorder(_ok)
    result = await _sender(recorder).send(message("apns", APNS_TOKEN))
    assert recorder.requests == []
    assert result.outcome is Outcome.FATAL


async def test_transport_error_is_retried_and_leaks_neither_token_nor_url(
    caplog: pytest.LogCaptureFixture, capsys: pytest.CaptureFixture[str]
) -> None:
    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError(f"All connection attempts failed for {request.url}")

    caplog.set_level(logging.DEBUG)
    result = await _sender(Recorder(boom)).send(
        message("apns", APNS_TOKEN, environment="production")
    )
    assert (result.outcome, result.code) == (Outcome.RETRY, "transport_error")
    seen = capsys.readouterr().out + caplog.text + repr(result)
    assert APNS_TOKEN not in seen
    assert "All connection attempts" not in seen


async def test_httpx_request_log_does_not_carry_the_device_token(
    caplog: pytest.LogCaptureFixture,
) -> None:
    # httpx logs "HTTP Request: POST <url>" at INFO; the APNs URL contains the token.
    caplog.set_level(logging.INFO)
    await _sender(Recorder(_ok)).send(message("apns", APNS_TOKEN, environment="production"))
    assert APNS_TOKEN not in caplog.text
