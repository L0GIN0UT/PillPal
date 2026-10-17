"""``build_senders``: every provider is present, real only when its settings are complete."""

from __future__ import annotations

import json

import httpx

from app.push.apns import ApnsSender
from app.push.base import Outcome
from app.push.disabled import DisabledPushSender
from app.push.fake import FakePushSender
from app.push.fcm import FcmSender
from app.push.registry import build_senders, close_senders
from app.push.rustore import RuStoreSender
from tests.conftest import make_settings
from tests.push.helpers import (
    FCM_TOKEN,
    Recorder,
    ec_private_pem,
    message,
    service_account_json,
)


async def test_nothing_configured_means_every_provider_is_disabled() -> None:
    senders = build_senders(make_settings())
    assert set(senders) == {"fcm", "apns", "rustore"}
    assert all(isinstance(sender, DisabledPushSender) for sender in senders.values())
    result = await senders["fcm"].send(message("fcm", FCM_TOKEN))
    assert (result.outcome, result.code) == (Outcome.FATAL, "provider_disabled")
    await close_senders(senders)


async def test_complete_settings_build_real_senders() -> None:
    settings = make_settings(
        fcm_project_id="example-project",
        fcm_service_account_json=service_account_json(),
        apns_team_id="ABCDE12345",
        apns_key_id="KEY1234567",
        apns_private_key=ec_private_pem(),
        apns_topic="app.example.pillpal",
        rustore_project_id="proj-1",
        rustore_service_token="service-token",
    )
    senders = build_senders(settings)
    assert isinstance(senders["fcm"], FcmSender)
    assert isinstance(senders["apns"], ApnsSender)
    assert isinstance(senders["rustore"], RuStoreSender)
    await close_senders(senders)


async def test_partial_settings_outside_prod_stay_disabled() -> None:
    senders = build_senders(make_settings(fcm_project_id="example-project"))
    assert isinstance(senders["fcm"], DisabledPushSender)
    await close_senders(senders)


async def test_eu_never_builds_a_rustore_sender() -> None:
    senders = build_senders(make_settings(region="eu"))
    assert isinstance(senders["rustore"], DisabledPushSender)
    await close_senders(senders)


async def test_apns_client_speaks_http2_and_senders_share_no_state() -> None:
    settings = make_settings(
        apns_team_id="ABCDE12345",
        apns_key_id="KEY1234567",
        apns_private_key=ec_private_pem(),
        apns_topic="app.example.pillpal",
    )
    senders = build_senders(settings)
    apns = senders["apns"]
    assert isinstance(apns, ApnsSender)
    assert apns._client._transport._pool._http2 is True  # type: ignore[attr-defined]
    await close_senders(senders)


async def test_fake_sender_records_messages_and_follows_its_script() -> None:
    fake = FakePushSender("fcm")
    assert (await fake.send(message("fcm", FCM_TOKEN))).outcome is Outcome.OK
    fake.results.append(fake.retry("quota"))
    assert (await fake.send(message("fcm", FCM_TOKEN))).outcome is Outcome.RETRY
    assert (await fake.send(message("fcm", FCM_TOKEN))).outcome is Outcome.OK
    assert [m.token for m in fake.sent] == [FCM_TOKEN] * 3
    assert json.loads(json.dumps(fake.sent[0].payload.to_wire()))["t"] == "missed"


def test_recorder_helper_builds_a_client() -> None:
    assert isinstance(Recorder(lambda r: httpx.Response(200)).client(), httpx.AsyncClient)
