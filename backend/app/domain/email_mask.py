"""Masked e-mail of an inviter (ADR 0020 section 3).

The invite preview shows ``ivan@mail.ru`` as ``i***@mail.ru``: enough for the scanner to
recognise who shares, not enough to harvest the address. A short local part is masked whole,
and a domain is kept in full only for large public mail providers: a private domain
(``ivanov.family``) would identify the person on its own, so it becomes ``i***.family``. Only a
holder of an open invite token sees the result, and it is never logged.
"""

from __future__ import annotations

MASK = "***"
# A local part this short would be revealed by its first character: mask it whole.
MIN_LOCAL_TO_HINT = 3
# Domains shared by millions of users: showing them names nobody.
PUBLIC_MAIL_DOMAINS = frozenset(
    {
        "mail.ru",
        "bk.ru",
        "inbox.ru",
        "list.ru",
        "yandex.ru",
        "ya.ru",
        "gmail.com",
        "icloud.com",
        "outlook.com",
        "hotmail.com",
        "rambler.ru",
        "proton.me",
    }
)


def _mask_local(local: str) -> str:
    return f"{local[0]}{MASK}" if len(local) >= MIN_LOCAL_TO_HINT else MASK


def _mask_domain(domain: str) -> str:
    if domain.lower() in PUBLIC_MAIL_DOMAINS:
        return domain
    name, dot, tld = domain.rpartition(".")
    if not dot or not name or not tld:
        return f"{domain[0]}{MASK}"
    return f"{name[0]}{MASK}.{tld}"


def mask_email(email: str) -> str:
    """``i***@mail.ru``, ``***@mail.ru`` (short local part), ``i***@i***.family``; ``***`` if
    the address is malformed."""
    local, at, domain = email.strip().rpartition("@")
    if not at or not local or not domain:
        return MASK
    return f"{_mask_local(local)}@{_mask_domain(domain)}"
