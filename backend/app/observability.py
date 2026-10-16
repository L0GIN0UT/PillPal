"""Structured JSON logging, request-id propagation and access logging.

Rules (TZ §3): logs are JSON with a request id; medical data, passwords,
tokens and full e-mail addresses are never logged. Request and response
bodies are never logged; the access log carries method, route template
(never the raw path, which may embed ids), status and duration only.
"""

from __future__ import annotations

import logging
import re
import sys
import time
import traceback
import uuid
from collections.abc import MutableMapping
from typing import Any, TextIO

import structlog
from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.errors import internal_error_response

REQUEST_ID_HEADER = "X-Request-ID"
UNMATCHED_ROUTE = "<unmatched>"
_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")

# Keys whose values must never reach a log sink, whatever logged them.
SENSITIVE_KEYS = frozenset(
    {
        "password",
        "new_password",
        "password_hash",
        "token",
        "access_token",
        "refresh_token",
        "authorization",
        "code",
        "email",
        "name",
        "notes",
        "note",
        "display_name",
        "rule",
        "restore_ticket",
    }
)

# Keys scrubbed from error-tracker events at any depth (request bodies, headers, breadcrumbs,
# stack frame variables, extras). The restore ticket is a bearer secret in an error body.
SENTRY_SECRET_KEYS = frozenset(
    {
        "restore_ticket",
        "refresh_token",
        "access_token",
        "token",
        "authorization",
        "password",
        "new_password",
        "code",
        "cookie",
        "set-cookie",
    }
)
FILTERED = "[Filtered]"


def _scrub(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: FILTERED if str(key).lower() in SENTRY_SECRET_KEYS else _scrub(item)
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [_scrub(item) for item in value]
    return value


def scrub_sentry_event(event: dict[str, Any], hint: Any = None) -> dict[str, Any] | None:
    """``before_send`` hook for the error tracker: remove bearer secrets from an event.

    The SDK itself arrives with the deployment (``docs/phase3-plan.md``, Phase 5); the hook is
    ready and tested so that ``details.restore_ticket`` of ``account_pending_deletion`` can
    never leave the process (ADR 0010 §2).
    """
    scrubbed: dict[str, Any] = _scrub(event)
    return scrubbed


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
    # Route stdlib logging (uvicorn, alembic, asyncpg, ...) through the same JSON
    # renderer so every line on stdout is machine-readable.
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
    # Our middleware writes the access log; uvicorn's would duplicate it.
    logging.getLogger("uvicorn.access").disabled = True


def get_logger(name: str) -> Any:
    return structlog.get_logger(name)


_access_log = get_logger("pillpal.access")
_error_log = get_logger("pillpal.error")


def _incoming_request_id(scope: Scope) -> str | None:
    for key, value in scope.get("headers", ()):
        if key == b"x-request-id":
            try:
                candidate = value.decode("ascii")
            except UnicodeDecodeError:
                return None
            return candidate if _REQUEST_ID_RE.match(candidate) else None
    return None


def _route_template(scope: Scope) -> str:
    # The router stores the matched route in the (shared) scope dict.
    route = scope.get("route")
    path = getattr(route, "path", None)
    return path if isinstance(path, str) else UNMATCHED_ROUTE


class RequestContextMiddleware:
    """Pure ASGI middleware: request id, access log and last-resort 500 handler.

    It sits outside the routing/exception layers, so even an unhandled
    exception produces the error envelope *with* the ``X-Request-ID`` header.
    """

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        request_id = _incoming_request_id(scope) or uuid.uuid4().hex
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
            # Type and frames only: exception messages may embed SQL parameters
            # or other user data.
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
