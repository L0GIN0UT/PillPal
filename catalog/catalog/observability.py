"""Structured JSON logging and the access log.

The catalog sees what people search for and which packages they scan, so the access log is
deliberately poor: method, route template (never the raw path or query string), status,
duration and a random per-request id. No client IP, user agent, headers or bodies, and the
request id is always generated here, never taken from the client.
"""

from __future__ import annotations

import logging
import sys
import time
import traceback
import uuid
from collections.abc import MutableMapping
from typing import Any, TextIO

import structlog
from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from catalog.errors import internal_error_response

REQUEST_ID_HEADER = "X-Request-ID"
UNMATCHED_ROUTE = "<unmatched>"

# Keys whose values never reach a log sink, whatever logged them.
SENSITIVE_KEYS = frozenset(
    {
        "authorization",
        "token",
        "access_token",
        "password",
        "cookie",
        "ip",
        "client_ip",
        "install",
        "q",
        # What a person looked up or scanned (ADR 0015 section 3).
        "gtin",
        "product_id",
        "catalog_product_id",
    }
)


def redact_sensitive(
    _: Any, __: str, event_dict: MutableMapping[str, Any]
) -> MutableMapping[str, Any]:
    for key in list(event_dict):
        if key.lower() in SENSITIVE_KEYS:
            event_dict[key] = "[redacted]"
    return event_dict


class _StdoutLogger:
    """Writes to the *current* ``sys.stdout`` (keeps pytest's capsys working)."""

    def msg(self, message: str) -> None:
        out: TextIO = sys.stdout
        out.write(message + "\n")
        out.flush()

    log = debug = info = warning = warn = error = critical = exception = msg


def _logger_factory(*_: Any) -> _StdoutLogger:
    return _StdoutLogger()


class _StdoutHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        try:
            sys.stdout.write(self.format(record) + "\n")
            sys.stdout.flush()
        except Exception:  # pragma: no cover - logging must never raise
            self.handleError(record)


def configure_logging(level: str = "INFO") -> None:
    shared: list[Any] = [
        structlog.contextvars.merge_contextvars,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso", utc=True),
        redact_sensitive,
    ]
    structlog.configure(
        processors=[*shared, structlog.processors.JSONRenderer()],
        wrapper_class=structlog.make_filtering_bound_logger(logging.getLevelName(level)),
        logger_factory=_logger_factory,
        cache_logger_on_first_use=False,
    )
    # Route stdlib logging (uvicorn, alembic, asyncpg, ...) through the same JSON renderer.
    handler = _StdoutHandler()
    handler.setFormatter(
        structlog.stdlib.ProcessorFormatter(
            processor=structlog.processors.JSONRenderer(),
            foreign_pre_chain=[structlog.stdlib.add_logger_name, *shared],
        )
    )
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers = []
        logging.getLogger(name).propagate = True
    # Our middleware writes the access log; uvicorn's would add the client address.
    logging.getLogger("uvicorn.access").disabled = True


def get_logger(name: str) -> Any:
    return structlog.get_logger(name)


_access_log = get_logger("catalog.access")
_error_log = get_logger("catalog.error")


def _route_template(scope: Scope) -> str:
    # The router stores the matched route in the (shared) scope dict.
    path = getattr(scope.get("route"), "path", None)
    return path if isinstance(path, str) else UNMATCHED_ROUTE


class RequestContextMiddleware:
    """Pure ASGI middleware: request id, access log and last-resort 500 handler."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        request_id = uuid.uuid4().hex
        structlog.contextvars.clear_contextvars()
        structlog.contextvars.bind_contextvars(request_id=request_id)
        started = time.perf_counter()
        state: dict[str, Any] = {"status": 500, "response_started": False}

        async def send_wrapper(message: Message) -> None:
            if message["type"] == "http.response.start":
                state["status"] = message["status"]
                state["response_started"] = True
                MutableHeaders(scope=message)[REQUEST_ID_HEADER] = request_id
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception as exc:
            # Type and frames only: exception messages may embed SQL parameters or user input.
            _error_log.error(
                "unhandled_exception",
                exc_type=type(exc).__name__,
                stack="".join(traceback.format_tb(exc.__traceback__)),
            )
            if not state["response_started"]:
                response = internal_error_response()
                response.headers[REQUEST_ID_HEADER] = request_id
                await response(scope, receive, send)
            state["status"] = 500
        finally:
            _access_log.info(
                "http_request",
                method=scope.get("method"),
                route=_route_template(scope),
                status=state["status"],
                duration_ms=round((time.perf_counter() - started) * 1000, 2),
            )
            structlog.contextvars.clear_contextvars()
