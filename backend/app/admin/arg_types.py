"""Argument types of ``python -m app.admin``.

They raise ``ArgumentTypeError`` only: argparse echoes the value of any other exception, and an
actor typed by mistake as an e-mail must not reach the terminal log.
"""

from __future__ import annotations

import argparse
import uuid
from datetime import datetime

from app.db.entitlements import MAX_ACTOR_LENGTH
from app.db.promo import MAX_GRANT_DAYS, MAX_LABEL_LENGTH

MAX_CODES_PER_RUN = 100
MAX_LIST_ROWS = 1000


def actor_arg(value: str) -> str:
    text = value.strip()
    if not 1 <= len(text) <= MAX_ACTOR_LENGTH or "@" in text or not text.isprintable():
        raise argparse.ArgumentTypeError(
            "must be a printable handle of 1..64 characters without '@'"
        )
    return text


def account_id_arg(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a UUID") from None


def expires_arg(value: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an ISO 8601 time with an offset") from None
    if parsed.tzinfo is None:
        raise argparse.ArgumentTypeError("must carry an offset, e.g. 2027-01-31T00:00:00+00:00")
    return parsed


def _int_between(value: str, low: int, high: int | None) -> int:
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be a whole number") from None
    if number < low or (high is not None and number > high):
        bound = f"at least {low}" if high is None else f"between {low} and {high}"
        raise argparse.ArgumentTypeError(f"must be {bound}")
    return number


def count_arg(value: str) -> int:
    return _int_between(value, 1, MAX_CODES_PER_RUN)


def max_activations_arg(value: str) -> int:
    return _int_between(value, 1, None)


def grant_days_arg(value: str) -> int:
    return _int_between(value, 1, MAX_GRANT_DAYS)


def list_limit_arg(value: str) -> int:
    return _int_between(value, 1, MAX_LIST_ROWS)


def label_arg(value: str) -> str:
    """A campaign name: it must hold no personal data, so no '@' (an e-mail) either."""
    text = value.strip()
    if not 1 <= len(text) <= MAX_LABEL_LENGTH or "@" in text or not text.isprintable():
        raise argparse.ArgumentTypeError(
            "must be a printable campaign name of 1..64 characters without '@'"
        )
    return text
