"""Reject oversized request bodies before they are read into memory (ADR 0011 section 6).

The public API takes tiny JSON objects, so a body over the cap is abuse or a bug. A declared
``Content-Length`` over the cap is refused outright; a chunked or lying body is cut off as soon as
the bytes received pass the cap. The response is the usual envelope and echoes nothing.

The overflow signal derives from ``BaseException`` on purpose: FastAPI turns any ``Exception``
raised while it reads the body into its own ``400``, which would hide the ``413``.
"""

from __future__ import annotations

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from catalog.errors import error_body


class _BodyTooLarge(BaseException):
    pass


class BodyLimitMiddleware:
    def __init__(self, app: ASGIApp, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        declared = dict(scope["headers"]).get(b"content-length", b"")
        if declared.isdigit() and int(declared) > self.max_bytes:
            await self._refuse(scope, receive, send)
            return
        received = 0
        started = False

        async def counting_receive() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    raise _BodyTooLarge
            return message

        async def tracking_send(message: Message) -> None:
            nonlocal started
            started = started or message["type"] == "http.response.start"
            await send(message)

        try:
            await self.app(scope, counting_receive, tracking_send)
        except _BodyTooLarge:
            # Caveat: an application that runs its handler in an anyio task group would wrap this
            # in a ``BaseExceptionGroup`` and the 413 would be lost; FastAPI's own request path
            # does not, and ``test_a_chunked_body_without_content_length_is_413_too`` covers it.
            if not started:
                await self._refuse(scope, receive, send)

    @staticmethod
    async def _refuse(scope: Scope, receive: Receive, send: Send) -> None:
        response = JSONResponse(
            error_body("payload_too_large", "Payload too large"), status_code=413
        )
        await response(scope, receive, send)
