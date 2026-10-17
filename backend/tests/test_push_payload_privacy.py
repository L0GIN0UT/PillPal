"""End to end: what actually goes to FCM and APNs for a missed-dose push carries ids only
(ADR 0008 §2, privacy rule 1)."""

from __future__ import annotations

import json
import uuid

import httpx
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.push.apns import ApnsSender
from app.push.fcm import FcmSender
from tests.conftest import FakeClock
from tests.helpers import (
    create_managed_profile,
    create_medication,
    create_schedule,
    link_accounts,
    register,
)
from tests.push.helpers import Recorder, ec_private_pem, service_account_json
from tests.push_helpers import APNS_TOKEN, put_token
from tests.push_outbox_helpers import deliver, insert_outbox, outbox_rows

MEDICAL_TEXT = ("Aspirin", "100 mg", "after food", "08:00", "Synthetic Ward", "tablet")


async def test_requests_to_providers_carry_ids_and_enums_only(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    owner, android, ios = await register(client), await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    medication = await create_medication(client, owner, profile_id=ward)
    schedule = await create_schedule(client, owner, medication["id"])
    await link_accounts(client, owner, android, "viewer", ward)
    await link_accounts(client, owner, ios, "guardian", ward)
    await put_token(client, android, "android", token="fcm-token-android")
    await put_token(
        client, ios, "ios", provider="apns", token=APNS_TOKEN, apns_environment="production"
    )
    for user in (android, ios):
        await insert_outbox(engine, user, ward, medication_id=medication["id"])

    clock = FakeClock()
    clock.advance(seconds=5)

    def fcm_responder(request: httpx.Request) -> httpx.Response:
        if request.url.host == "oauth2.googleapis.com":
            return httpx.Response(200, json={"access_token": "ya29.t", "expires_in": 3600})
        return httpx.Response(200, json={})

    fcm_calls = Recorder(fcm_responder)
    apns_calls = Recorder(lambda request: httpx.Response(200))
    senders = {
        "fcm": FcmSender(
            project_id="example-project",
            service_account_json=service_account_json(),
            client=fcm_calls.client(),
            clock=clock,
        ),
        "apns": ApnsSender(
            team_id="ABCDE12345",
            key_id="KEY1234567",
            private_key=ec_private_pem(),
            topic="app.example.pillpal",
            client=apns_calls.client(http2=True),
            clock=clock,
        ),
    }
    senders["rustore"] = senders["fcm"]  # unused here
    report = await deliver(maker, settings, senders, clock)  # type: ignore[arg-type]
    assert report.sent == 2

    fcm_body = fcm_calls.requests[-1].content.decode()
    apns_body = apns_calls.requests[-1].content.decode()
    wire = [json.loads(fcm_body)["message"]["data"], json.loads(apns_body)]
    for sent in (
        fcm_body,
        apns_body,
        str(fcm_calls.requests[-1].url),
        str(apns_calls.requests[-1].url),
    ):
        for needle in (*MEDICAL_TEXT, schedule["id"], f"{schedule['id']}/"):
            assert needle not in sent, needle
    # FCM carries the medication id (the device looks the name up locally); APNs does not.
    assert medication["id"] in fcm_body
    assert medication["id"] not in apns_body
    allowed = {"v", "t", "a", "p", "m", "g", "s"}
    assert set(wire[0]) <= allowed
    assert set(wire[1]) <= allowed | {"aps"}
    for value in (v for k, v in wire[0].items() if k in "apmg"):
        assert uuid.UUID(value)
    stored = await outbox_rows(engine)
    assert all(set(r.payload) <= allowed for r in stored)
    assert all(medication["id"] in r.payload.values() for r in stored)
