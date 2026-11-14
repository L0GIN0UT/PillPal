"""Masked e-mail of an inviter (ADR 0020 section 3).

The invite preview shows ``i***@mail.ru``: enough for the scanner to recognise who shares, not
enough to harvest the address. Only a holder of an open invite token sees it, and it is never
logged.
"""

from __future__ import annotations

MASK = "***"


def mask_email(email: str) -> str:
    """First character of the local part, ``***`` and the full domain; ``***`` if malformed."""
    local, at, domain = email.strip().rpartition("@")
    if not at or not local or not domain:
        return MASK
    return f"{local[0]}{MASK}@{domain}"
