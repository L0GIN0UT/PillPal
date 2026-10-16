"""Uniform error envelope: every error response is ``{"error": {"code", "message"}}``.

Messages are fixed strings chosen by the server; client input and exception
text are never echoed, so no stack traces or user data leak through errors.
"""

from __future__ import annotations

from typing import Any, cast

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException


class AppError(Exception):
    """An expected error that maps to an HTTP response."""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        headers: dict[str, str] | None = None,
    ) -> None:
        super().__init__(code)
        self.status_code = status_code
        self.code = code
        self.message = message
        self.headers = headers


def not_found() -> AppError:
    return AppError(404, "not_found", "Not found")


def unauthorized(code: str = "unauthorized", message: str = "Authentication required") -> AppError:
    return AppError(401, code, message, headers={"WWW-Authenticate": "Bearer"})


def request_validation_error(
    exc: ValidationError, loc_prefix: tuple[str, ...]
) -> RequestValidationError:
    """Re-raise a nested model's ValidationError as a request 422 (located in the body)."""
    return RequestValidationError(
        [
            {"loc": (*loc_prefix, *e["loc"]), "msg": e["msg"], "type": e["type"]}
            for e in exc.errors()
        ]
    )


_HTTP_CODES: dict[int, tuple[str, str]] = {
    400: ("bad_request", "Bad request"),
    401: ("unauthorized", "Authentication required"),
    403: ("forbidden", "Forbidden"),
    404: ("not_found", "Not found"),
    405: ("method_not_allowed", "Method not allowed"),
    409: ("conflict", "Conflict"),
    413: ("payload_too_large", "Payload too large"),
    415: ("unsupported_media_type", "Unsupported media type"),
    429: ("rate_limited", "Too many requests"),
}


def error_body(code: str, message: str, **extra: Any) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, **extra}}


def internal_error_response() -> JSONResponse:
    return JSONResponse(error_body("internal_error", "Internal server error"), status_code=500)


async def _app_error(_: Request, exc: Exception) -> JSONResponse:
    err = cast(AppError, exc)
    return JSONResponse(
        error_body(err.code, err.message), status_code=err.status_code, headers=err.headers
    )


async def _http_error(_: Request, exc: Exception) -> JSONResponse:
    err = cast(StarletteHTTPException, exc)
    code, message = _HTTP_CODES.get(err.status_code, ("http_error", "Request failed"))
    if err.status_code >= 500:
        code, message = "internal_error", "Internal server error"
    return JSONResponse(error_body(code, message), status_code=err.status_code, headers=err.headers)


async def _validation_error(_: Request, exc: Exception) -> JSONResponse:
    # Only location and message: pydantic's ``input``/``ctx`` may contain secrets
    # (passwords) or medical data (medication names).
    errors = cast(RequestValidationError, exc).errors()
    details = [{"loc": list(e.get("loc", ())), "msg": str(e.get("msg", ""))} for e in errors]
    return JSONResponse(
        error_body("validation_error", "Request validation failed", details=details),
        status_code=422,
    )


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AppError, _app_error)
    app.add_exception_handler(StarletteHTTPException, _http_error)
    app.add_exception_handler(RequestValidationError, _validation_error)
