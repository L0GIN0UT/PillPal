"""Plain-text mail templates: RU + EN in one body, no medical data, the code only in the body."""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from app.email import EmailKind
from app.email_templates import render

CODE = "482913"
ERASE_AFTER = datetime(2026, 11, 16, 8, 30, tzinfo=UTC)
CODE_KINDS: tuple[EmailKind, ...] = ("verify_email", "password_reset", "restore_account")
NOTICE_KINDS: tuple[EmailKind, ...] = (
    "account_exists",
    "deletion_requested",
    "account_restored",
    "account_pending_deletion",
)


def _cyrillic(text: str) -> bool:
    return any("Ѐ" <= ch <= "ӿ" for ch in text)


@pytest.mark.parametrize("kind", CODE_KINDS)
def test_code_mail_has_the_code_in_the_body_only(kind: EmailKind) -> None:
    subject, body = render(kind, code=CODE, ttl_minutes=15)
    assert CODE in body
    assert CODE not in subject
    assert "15" in body


@pytest.mark.parametrize("kind", [*CODE_KINDS, *NOTICE_KINDS])
def test_every_kind_is_bilingual_and_neutral(kind: EmailKind) -> None:
    code = CODE if kind in CODE_KINDS else None
    subject, body = render(kind, code=code, ttl_minutes=15, erase_after=ERASE_AFTER)
    assert subject.startswith("PillPal")
    assert _cyrillic(subject)
    assert _cyrillic(body)
    assert any(word in body for word in ("If you", "you", "You"))
    assert "\n" not in subject


@pytest.mark.parametrize("kind", NOTICE_KINDS)
def test_notices_carry_no_code(kind: EmailKind) -> None:
    _, body = render(kind, code=None, ttl_minutes=15, erase_after=ERASE_AFTER)
    assert not any(ch.isdigit() for ch in body.replace("2026-11-16 08:30 UTC", ""))


@pytest.mark.parametrize("kind", ["deletion_requested", "account_pending_deletion"])
def test_deletion_notices_say_when_the_data_is_erased(kind: EmailKind) -> None:
    _, body = render(kind, code=None, ttl_minutes=15, erase_after=ERASE_AFTER)
    assert "2026-11-16 08:30 UTC" in body


def test_code_kind_without_a_code_is_a_programming_error() -> None:
    with pytest.raises(ValueError, match="code"):
        render("verify_email", code=None, ttl_minutes=15)
