"""Promo codes: alphabet, normalisation and digest (ADR 0018 section 3). Pure, no IO.

A code is drawn from 31 symbols (no 0, O, 1, I, L). Only its keyed digest is stored. The local
variable and parameter name ``promo_code`` is deliberate: the log and error-tracker scrubbers
filter that key (``app.observability``), so a frame that holds a code never leaks it.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
from collections.abc import Callable

ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
GROUP_SIZE = 4
MIN_CODE_LENGTH = 16
# The input limit of the endpoint; a code is never longer than this.
MAX_INPUT_LENGTH = 64
# Separators a person types or copies; nothing else is stripped.
_SEPARATORS = frozenset(" -")
# Accepted before any case mapping: the alphabet and its ASCII lowercase form. Unicode case
# mapping would let characters such as U+017F (long s) or U+212A (Kelvin) become ASCII letters.
_ACCEPTED = frozenset(ALPHABET) | frozenset(ALPHABET.lower())


def generate_code(length: int, choice: Callable[[str], str] = secrets.choice) -> str:
    """A random code of ``length`` symbols; ``choice`` is injectable for tests only."""
    return "".join(choice(ALPHABET) for _ in range(length))


def group_code(promo_code: str) -> str:
    """The code as shown to the operator and the user: groups of four joined by hyphens."""
    return "-".join(promo_code[i : i + GROUP_SIZE] for i in range(0, len(promo_code), GROUP_SIZE))


def normalize_promo_code(promo_code: str) -> str | None:
    """Remove spaces and hyphens, then accept only the alphabet (or its lowercase) in ASCII.

    The check runs on the characters as typed, before uppercasing; ``None`` means invalid.
    """
    kept = [char for char in promo_code if char not in _SEPARATORS]
    if not kept or any(char not in _ACCEPTED for char in kept):
        return None
    return "".join(kept).upper()


def code_digest(key: bytes, promo_code: str) -> str:
    """``HMAC-SHA256(key, normalised code)`` as lower-case hex: the stored, unique lookup value."""
    return hmac.new(key, promo_code.encode("ascii"), hashlib.sha256).hexdigest()
