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
    "export_requested",
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


def test_the_export_notice_has_no_link_and_no_data() -> None:
    subject, body = render("export_requested", code=None, ttl_minutes=15)
    assert "http" not in subject + body
    assert "://" not in body


@pytest.mark.parametrize("kind", ["identity_linked", "identity_unlinked"])
@pytest.mark.parametrize(
    ("provider", "shown"),
    [("apple", "Apple"), ("google", "Google"), ("vk_id", "VK ID"), ("yandex_id", "Yandex ID")],
)
def test_identity_notices_name_the_provider_only(
    kind: EmailKind, provider: str, shown: str
) -> None:
    subject, body = render(kind, code=None, ttl_minutes=15, provider=provider)
    assert shown in body
    assert "@" not in subject + body  # no address, no subject of the provider
    assert "http" not in subject + body
    assert _cyrillic(body)


def test_an_identity_notice_without_a_provider_is_a_programming_error() -> None:
    with pytest.raises(ValueError, match="provider"):
        render("identity_linked", code=None, ttl_minutes=15)


def test_identity_notices_tell_what_to_do_in_both_languages() -> None:
    for kind in ("identity_linked", "identity_unlinked"):
        _, body = render(kind, code=None, ttl_minutes=15, provider="google")
        assert "remove this sign-in method in Settings and reset your password" in body
        assert "удалите этот способ входа в настройках и сбросьте пароль" in body


def test_golden_code_mail_text() -> None:
    _, body = render("verify_email", code=CODE, ttl_minutes=15)
    assert body == (
        "Код подтверждения: 482913\n"
        "Введите этот код в приложении, чтобы подтвердить адрес и закончить регистрацию.\n"
        "Код действует 15 мин. Если это были не вы, просто проигнорируйте это письмо.\n\n"
        "Письмо отправлено автоматически, отвечать на него не нужно.\n\n--\n\n"
        "Confirmation code: 482913\n"
        "Enter this code in the app to confirm your address and finish signing up.\n"
        "It is valid for 15 minutes. If this was not you, ignore this email.\n\n"
        "This message was sent automatically; no reply is needed."
    )


def test_golden_deletion_notice_text() -> None:
    _, body = render("deletion_requested", code=None, ttl_minutes=15, erase_after=ERASE_AFTER)
    assert body == (
        "Запрошено удаление аккаунта. Данные будут стёрты не позднее 2026-11-16 08:30 UTC. "
        "До этого срока аккаунт можно восстановить, войдя в приложение. "
        "Если это были не вы, смените пароль.\n\n"
        "Письмо отправлено автоматически, отвечать на него не нужно.\n\n--\n\n"
        "Deletion of your account was requested. Its data will be erased by 2026-11-16 08:30 UTC. "
        "Until then you can restore the account by signing in to the app. "
        "If this was not you, change your password.\n\n"
        "This message was sent automatically; no reply is needed."
    )


def test_golden_identity_notice_text() -> None:
    _, body = render("identity_linked", code=None, ttl_minutes=15, provider="google")
    assert body == (
        "К вашему аккаунту добавлен вход через Google. "
        "Если это были не вы, удалите этот способ входа в настройках и сбросьте пароль.\n\n"
        "Письмо отправлено автоматически, отвечать на него не нужно.\n\n--\n\n"
        "Sign-in with Google was added to your account. "
        "If this was not you, remove this sign-in method in Settings and reset your password.\n\n"
        "This message was sent automatically; no reply is needed."
    )
