"""Invite link hosting (ADR 0009 §3): app-link verification files and the static landing page.

These routes touch neither the database nor Redis, so each test builds its own app
with the settings under test.
"""

from __future__ import annotations

import base64
import hashlib
import re
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import pytest
from httpx import ASGITransport, AsyncClient

from app.email import InMemoryEmailSender
from app.main import create_app
from tests.conftest import make_settings

FINGERPRINT = ":".join(["AB"] * 32)
OTHER_FINGERPRINT = ":".join(["01"] * 32)
ANDROID = {"android_package_name": "app.pillpal.example", "android_cert_sha256s": [FINGERPRINT]}
IOS = {"apple_team_id": "ABCDE12345", "ios_bundle_id": "app.pillpal.example"}


@asynccontextmanager
async def links_client(**settings: Any) -> AsyncIterator[AsyncClient]:
    app = create_app(make_settings(**settings), email_sender=InMemoryEmailSender())
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        yield client


# --- assetlinks.json ----------------------------------------------------------------------


async def test_assetlinks_lists_package_and_fingerprints() -> None:
    settings = {**ANDROID, "android_cert_sha256s": [FINGERPRINT, OTHER_FINGERPRINT]}
    async with links_client(**settings) as client:
        resp = await client.get("/.well-known/assetlinks.json", follow_redirects=False)
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/json"
    assert resp.headers["x-content-type-options"] == "nosniff"
    assert resp.json() == [
        {
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": "app.pillpal.example",
                "sha256_cert_fingerprints": [FINGERPRINT, OTHER_FINGERPRINT],
            },
        }
    ]


@pytest.mark.parametrize(
    "settings",
    [
        {},
        {"android_package_name": "app.pillpal.example"},
        {"android_cert_sha256s": [FINGERPRINT]},
        IOS,
    ],
)
async def test_assetlinks_is_404_until_package_and_certificates_are_configured(
    settings: dict[str, Any],
) -> None:
    async with links_client(**settings) as client:
        resp = await client.get("/.well-known/assetlinks.json", follow_redirects=False)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "not_found"


async def test_prod_never_publishes_a_debug_certificate() -> None:
    with pytest.raises(ValueError, match="debug"):
        make_settings(
            environment="prod",
            **ANDROID,
            android_debug_cert_sha256s=[FINGERPRINT],
        )


# --- apple-app-site-association -----------------------------------------------------------------


async def test_apple_association_claims_only_the_invite_path() -> None:
    async with links_client(**IOS) as client:
        resp = await client.get("/.well-known/apple-app-site-association", follow_redirects=False)
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/json"
    details = resp.json()["applinks"]["details"]
    assert len(details) == 1
    assert details[0]["appIDs"] == ["ABCDE12345.app.pillpal.example"]
    assert [component["/"] for component in details[0]["components"]] == ["/i"]


@pytest.mark.parametrize(
    "settings",
    [{}, {"apple_team_id": "ABCDE12345"}, {"ios_bundle_id": "app.pillpal.example"}, ANDROID],
)
async def test_apple_association_is_404_until_both_ids_are_configured(
    settings: dict[str, Any],
) -> None:
    async with links_client(**settings) as client:
        resp = await client.get("/.well-known/apple-app-site-association", follow_redirects=False)
    assert resp.status_code == 404


async def test_well_known_files_are_served_without_redirects_and_not_documented() -> None:
    async with links_client(**ANDROID, **IOS) as client:
        for path in ("/.well-known/assetlinks.json", "/.well-known/apple-app-site-association"):
            assert (await client.get(path, follow_redirects=False)).status_code == 200
        schema = (await client.get("/openapi.json")).json()
    assert not [p for p in schema["paths"] if p.startswith(("/.well-known", "/i"))]


# --- GET /i ---------------------------------------------------------------------------------------


async def test_landing_page_is_static_private_and_locked_down() -> None:
    async with links_client() as client:
        resp = await client.get("/i", follow_redirects=False)
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/html")
    assert resp.headers["cache-control"] == "no-store"
    assert resp.headers["referrer-policy"] == "no-referrer"
    assert resp.headers["x-content-type-options"] == "nosniff"
    assert "set-cookie" not in resp.headers
    csp = resp.headers["content-security-policy"]
    for directive in ("default-src 'none'", "frame-ancestors 'none'", "base-uri 'none'"):
        assert directive in csp
    assert "unsafe" not in csp
    assert "script-src" not in csp  # nothing may run: default-src 'none' covers it


async def test_landing_page_loads_nothing_and_never_touches_the_token() -> None:
    async with links_client() as client:
        body = (await client.get("/i")).text
    assert not re.search(r"https?://", body)  # no third-party (or any) resources
    assert not re.search(r"<(script|link|img|iframe|form|object|embed)\b", body, re.IGNORECASE)
    assert "location" not in body.lower()
    assert "token" not in body.lower()


async def test_landing_page_style_is_allowed_by_hash_only() -> None:
    async with links_client() as client:
        resp = await client.get("/i")
    style = re.search(r"<style>(.*?)</style>", resp.text, re.DOTALL)
    assert style is not None
    digest = base64.b64encode(hashlib.sha256(style.group(1).encode()).digest()).decode()
    assert f"style-src 'sha256-{digest}'" in resp.headers["content-security-policy"]


async def test_landing_page_ignores_the_query_and_refuses_other_methods() -> None:
    async with links_client() as client:
        plain = await client.get("/i")
        with_query = await client.get("/i?t=anything")
        posted = await client.post("/i", json={"token": "x"})
    assert plain.text == with_query.text
    assert posted.status_code == 405
