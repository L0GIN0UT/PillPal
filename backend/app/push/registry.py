"""``build_senders``: one sender per provider, real when configured, disabled otherwise."""

from __future__ import annotations

import httpx

from app.config import Settings
from app.push.apns import ApnsSender
from app.push.base import PushProvider, PushSender
from app.push.disabled import DisabledPushSender
from app.push.fcm import FcmSender
from app.push.rustore import RuStoreSender


def _client(settings: Settings, *, http2: bool = False) -> httpx.AsyncClient:
    # Redirects are never followed (a provider never needs one, and a redirect would carry
    # the bearer credential elsewhere); no environment proxies, no cookies.
    return httpx.AsyncClient(
        timeout=httpx.Timeout(settings.push_send_timeout_seconds),
        http2=http2,
        follow_redirects=False,
        trust_env=False,
    )


def _fcm(settings: Settings) -> PushSender:
    if settings.fcm_project_id is None or settings.fcm_service_account_json is None:
        return DisabledPushSender("fcm")
    return FcmSender(
        project_id=settings.fcm_project_id,
        service_account_json=settings.fcm_service_account_json.get_secret_value(),
        client=_client(settings),
    )


def _apns(settings: Settings) -> PushSender:
    if (
        settings.apns_team_id is None
        or settings.apns_key_id is None
        or settings.apns_private_key is None
        or settings.apns_topic is None
    ):
        return DisabledPushSender("apns")
    return ApnsSender(
        team_id=settings.apns_team_id,
        key_id=settings.apns_key_id,
        private_key=settings.apns_private_key.get_secret_value(),
        topic=settings.apns_topic,
        client=_client(settings, http2=True),
    )


def _rustore(settings: Settings) -> PushSender:
    if (
        settings.region != "ru"  # defence in depth: the settings validator refuses it too
        or settings.rustore_project_id is None
        or settings.rustore_service_token is None
    ):
        return DisabledPushSender("rustore")
    return RuStoreSender(
        project_id=settings.rustore_project_id,
        service_token=settings.rustore_service_token.get_secret_value(),
        client=_client(settings),
    )


def build_senders(settings: Settings) -> dict[PushProvider, PushSender]:
    return {"fcm": _fcm(settings), "apns": _apns(settings), "rustore": _rustore(settings)}


async def close_senders(senders: dict[PushProvider, PushSender]) -> None:
    for sender in senders.values():
        await sender.aclose()
