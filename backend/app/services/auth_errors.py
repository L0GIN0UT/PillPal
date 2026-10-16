"""Stable auth error factories (codes are part of the API contract)."""

from app.errors import AppError, unauthorized


def invalid_credentials() -> AppError:
    return unauthorized("invalid_credentials", "Invalid e-mail or password")


def invalid_token() -> AppError:
    return unauthorized("invalid_token", "Invalid or expired refresh token")


def invalid_code() -> AppError:
    return AppError(400, "invalid_code", "Invalid or expired code")


def account_pending_deletion(details: dict[str, str] | None = None) -> AppError:
    return AppError(
        403,
        "account_pending_deletion",
        "This account is scheduled for deletion; restore it to continue",
        details=details,
    )


def wrong_region() -> AppError:
    return AppError(409, "wrong_region", "This account belongs to another data region server")
