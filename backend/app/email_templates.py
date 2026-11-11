"""Mail bodies, Russian first and English below (the address has no known locale).

Privacy (``.claude/rules/privacy.md`` 1): a mail says what happened to the *account*, never what
is in it - no medication, schedule or dose wording. Subjects are neutral and never hold the code;
the code appears in the body only. Notices carry no code and no link. The strings live in
``app.email_copy``; the text part is built here, the HTML part in ``app.email_html``.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import NamedTuple

from app.email import EmailKind
from app.email_copy import CODE_KINDS, NOTICES, PROVIDER_NAMES, LangCopy
from app.email_html import render_html

_SEPARATOR = "\n\n--\n\n"
_PROVIDER_KINDS = ("identity_linked", "identity_unlinked")

__all__ = ["PROVIDER_NAMES", "RenderedMail", "render", "render_mail"]


class RenderedMail(NamedTuple):
    subject: str
    text: str
    html: str


def _format_instant(value: datetime | None) -> str:
    if value is None:
        return "-"
    return value.astimezone(UTC).strftime("%Y-%m-%d %H:%M UTC")


def _text_part(copy: LangCopy, values: dict[str, object]) -> str:
    lead = copy.lead.format(**values)
    if copy.ttl is None:
        return f"{lead} {copy.tail}"
    return f"{lead} {values['code']}\n{copy.ttl.format(**values)} {copy.tail}"


def _html_part(copy: LangCopy, subject: str, values: dict[str, object]) -> tuple[str, list[str]]:
    if copy.ttl is None:
        return subject[:1].upper() + subject[1:], [copy.lead.format(**values), copy.tail]
    return copy.lead.rstrip(":"), [copy.ttl.format(**values), copy.tail]


def render_mail(
    kind: EmailKind,
    *,
    code: str | None,
    ttl_minutes: int,
    erase_after: datetime | None = None,
    provider: str | None = None,
) -> RenderedMail:
    """Subject, text and HTML of one mail; codes only for the code kinds, dates for deletion, the
    provider name (never a subject or address of the provider) for the identity notices."""
    if kind in CODE_KINDS:
        if code is None:
            raise ValueError(f"{kind} needs a code")
        kcopy = CODE_KINDS[kind]
    else:
        kcopy = NOTICES[kind]
    if kind in _PROVIDER_KINDS and provider not in PROVIDER_NAMES:
        raise ValueError(f"{kind} needs a known provider")
    values: dict[str, object] = {
        "code": code or "",
        "ttl": ttl_minutes,
        "when": _format_instant(erase_after),
        "provider": PROVIDER_NAMES.get(provider or "", ""),
    }
    subject = f"PillPal: {kcopy.subject_ru} / {kcopy.subject_en}"
    text = _text_part(kcopy.ru, values) + _SEPARATOR + _text_part(kcopy.en, values)
    heading_ru, paragraphs_ru = _html_part(kcopy.ru, kcopy.subject_ru, values)
    heading_en, paragraphs_en = _html_part(kcopy.en, kcopy.subject_en, values)
    html = render_html(
        title=subject,
        heading_ru=heading_ru,
        paragraphs_ru=paragraphs_ru,
        heading_en=heading_en,
        paragraphs_en=paragraphs_en,
        code=code if kind in CODE_KINDS else None,
    )
    return RenderedMail(subject, text, html)


def render(
    kind: EmailKind,
    *,
    code: str | None,
    ttl_minutes: int,
    erase_after: datetime | None = None,
    provider: str | None = None,
) -> tuple[str, str]:
    """``(subject, body)``: the text part of :func:`render_mail`."""
    mail = render_mail(
        kind, code=code, ttl_minutes=ttl_minutes, erase_after=erase_after, provider=provider
    )
    return mail.subject, mail.text
