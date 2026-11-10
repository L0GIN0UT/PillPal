"""Promo codes: alphabet, normalisation and digest (ADR 0018 section 3). Pure, no IO.

A code is drawn from 31 symbols (no 0, O, 1, I, L). Only its keyed digest is stored. Plaintext
codes are held in variables named ``promo_code`` (or ``promo_codes``) only: the log and
error-tracker scrubbers filter those keys by name (``app.observability``), which is a safety net
for a frame dump and no guarantee; any other name is not filtered.
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
_STRIP_SEPARATORS = {ord(char): None for char in _SEPARATORS}
# Accepted before any case mapping: the alphabet and its ASCII lowercase form. Unicode case
# mapping would let characters such as U+017F (long s) or U+212A (Kelvin) become ASCII letters.
_ACCEPTED = frozenset(ALPHABET) | frozenset(ALPHABET.lower())


def generate_code(length: int, choice: Callable[[str], str] = secrets.choice) -> str:
    """A random code of ``length`` symbols; ``choice`` is injectable for tests only."""
    return "".join(choice(ALPHABET) for _ in range(length))


def group_code(promo_code: str) -> str:
    """The code as shown to the operator and the user: groups of four joined by hyphens."""
    return "-".join(promo_code[i : i + GROUP_SIZE] for i in range(0, len(promo_code), GROUP_SIZE))


def _is_code_text(promo_code: str) -> bool:
    """Only separators and alphabet symbols (ASCII, either case), and at least one symbol."""
    symbols = 0
    for char in promo_code:
        if char in _SEPARATORS:
            continue
        if char not in _ACCEPTED:
            return False
        symbols += 1
    return symbols > 0


def _canonical(promo_code: str) -> str:
    return promo_code.translate(_STRIP_SEPARATORS).upper()


def normalize_promo_code(promo_code: str) -> str | None:
    """Remove spaces and hyphens, then accept only the alphabet (or its lowercase) in ASCII.

    The check runs on the characters as typed, before uppercasing; ``None`` means invalid.
    """
    if not _is_code_text(promo_code):
        return None
    return _canonical(promo_code)


def code_digest(key: bytes, promo_code: str) -> str:
    """``HMAC-SHA256(key, normalised code)`` as lower-case hex: the stored, unique lookup value."""
    return hmac.new(key, promo_code.encode("ascii"), hashlib.sha256).hexdigest()


def lookup_digest(key: bytes, promo_code: str) -> str | None:
    """The digest to look a typed code up by, or ``None`` when the input cannot be a code."""
    if not _is_code_text(promo_code):
        return None
    promo_code = _canonical(promo_code)  # reassigned: no second name holds the plaintext
    return code_digest(key, promo_code)
