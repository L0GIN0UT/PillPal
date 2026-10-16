"""Hosting for invite links (ADR 0009 §3, owner decision D6).

* ``/.well-known/assetlinks.json`` and ``/.well-known/apple-app-site-association``
  let Android and iOS verify that this host's ``/i`` links belong to the app. Both come
  from Settings, are ``application/json`` and are never redirected; they are 404 until
  configured.
* ``GET /i`` is the page a browser shows when the app is not installed. It is static: it
  never contains or reads the token (the token lives in the URL fragment, which the
  browser does not send), loads nothing, is never cached, never leaks a referrer and
  cannot be framed.
"""

from __future__ import annotations

import base64
import hashlib

from fastapi import APIRouter
from fastapi.responses import HTMLResponse, JSONResponse

from app.deps import SettingsDep
from app.errors import not_found

router = APIRouter(tags=["links"], include_in_schema=False)

INVITE_PATH = "/i"

# The landing page is the one place with fixed human text: it is served to browsers
# without the app (and so without its localization), in both product languages.
_STYLE = "body{font-family:system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem}"
_LANDING_HTML = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>PillPal</title>
<style>{_STYLE}</style>
</head>
<body>
<h1>PillPal</h1>
<p lang="en">This is a PillPal invitation. Open the link on a phone where PillPal is installed.</p>
<p lang="ru">Это приглашение в PillPal. Откройте ссылку на телефоне, где установлено приложение.</p>
</body>
</html>
"""
_STYLE_HASH = base64.b64encode(hashlib.sha256(_STYLE.encode()).digest()).decode()
_LANDING_HEADERS = {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Content-Security-Policy": (
        f"default-src 'none'; style-src 'sha256-{_STYLE_HASH}'; "
        "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    ),
}


def _json_file(content: object, max_age: int) -> JSONResponse:
    return JSONResponse(
        content,
        media_type="application/json",
        headers={
            "Cache-Control": f"public, max-age={max_age}",
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.get("/.well-known/assetlinks.json")
async def asset_links(settings: SettingsDep) -> JSONResponse:
    if not settings.android_package_name or not settings.android_cert_sha256s:
        raise not_found()
    document = [
        {
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": settings.android_package_name,
                "sha256_cert_fingerprints": settings.android_cert_sha256s,
            },
        }
    ]
    return _json_file(document, settings.well_known_cache_seconds)


@router.get("/.well-known/apple-app-site-association")
async def apple_app_site_association(settings: SettingsDep) -> JSONResponse:
    if not settings.apple_team_id or not settings.ios_bundle_id:
        raise not_found()
    document = {
        "applinks": {
            "details": [
                {
                    "appIDs": [f"{settings.apple_team_id}.{settings.ios_bundle_id}"],
                    "components": [{"/": INVITE_PATH, "comment": "PillPal invite links"}],
                }
            ]
        }
    }
    return _json_file(document, settings.well_known_cache_seconds)


@router.get(INVITE_PATH)
async def invite_landing() -> HTMLResponse:
    return HTMLResponse(_LANDING_HTML, headers=_LANDING_HEADERS)
