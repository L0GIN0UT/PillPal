"""Body size limit of ``POST /v1/me/purchases`` (ADR 0018 section 6), a pure ASGI middleware.

FastAPI reads a body before any dependency runs, so the limit has to sit below it. A declared
``Content-Length`` over the limit is refused without reading; otherwise the body is read in chunks
and refused as soon as it passes the limit, then replayed to the application. The limit
(``PAYMENTS_MAX_BODY_BYTES``) is read from the settings on every request.

The path is matched by its suffix, so a ``root_path`` or mount prefix cannot bypass the limit. The
middleware sits outside CORS, so its 413 carries no CORS headers: the only client is the mobile
app. A reverse-proxy body limit belongs in front of it as well (``docs/staging.md``).
"""

from __future__ import annotations

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.config import Settings
from app.errors import error_body

PURCHASES_PATH = "/v1/me/purchases"


class PurchaseBodyLimit:
    def __init__(self, app: ASGIApp, settings: Settings) -> None:
        self._app = app
        self._settings = settings

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if (
            scope["type"] != "http"
            or not scope["path"].rstrip("/").endswith(PURCHASES_PATH)
            or scope["method"] != "POST"
        ):
            await self._app(scope, receive, send)
            return
        limit = self._settings.payments_max_body_bytes
        if _declared_length(scope) > limit:
            await _too_large(scope, receive, send)
            return
        chunks: list[bytes] = []
        size = 0
        more = True
        while more:
            message = await receive()
            if message["type"] != "http.request":  # the client went away
                return
            body: bytes = message.get("body", b"")
            size += len(body)
            if size > limit:
                await _too_large(scope, receive, send)
                return
            chunks.append(body)
            more = bool(message.get("more_body", False))
        buffered = b"".join(chunks)
        sent = False

        async def replay() -> Message:
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": buffered, "more_body": False}
            return await receive()

        await self._app(scope, replay, send)


def _declared_length(scope: Scope) -> int:
    for name, value in scope["headers"]:
        if name == b"content-length":
            try:
                return int(value)
            except ValueError:
                return 0
    return 0


async def _too_large(scope: Scope, receive: Receive, send: Send) -> None:
    response = JSONResponse(
        error_body("payload_too_large", "Payload too large"),
        status_code=413,
        headers={"Connection": "close"},
    )
    await response(scope, receive, send)
