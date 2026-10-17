"""Plain-text mail bodies, Russian first and English below (the address has no known locale).

Privacy (``.claude/rules/privacy.md`` 1): a mail says what happened to the *account*, never what
is in it - no medication, schedule or dose wording. Subjects are neutral and never hold the code;
the code appears in the body only. Notices carry no code and no link.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import NamedTuple

from app.email import EmailKind

_SEPARATOR = "\n\n--\n\n"
_IGNORE_RU = "Если это были не вы, просто проигнорируйте это письмо."
_IGNORE_EN = "If this was not you, ignore this email."
_CHANGE_RU = "Если это были не вы, смените пароль."
_CHANGE_EN = "If this was not you, change your password."


class _Text(NamedTuple):
    subject_ru: str
    subject_en: str
    body_ru: str
    body_en: str


_CODE_KINDS: dict[str, _Text] = {
    "verify_email": _Text(
        "подтверждение e-mail",
        "e-mail confirmation",
        "Код подтверждения e-mail: {code}\nКод действует {ttl} мин. " + _IGNORE_RU,
        "Your email confirmation code: {code}\nIt is valid for {ttl} minutes. " + _IGNORE_EN,
    ),
    "password_reset": _Text(
        "сброс пароля",
        "password reset",
        "Код для сброса пароля: {code}\nКод действует {ttl} мин. " + _IGNORE_RU,
        "Your password reset code: {code}\nIt is valid for {ttl} minutes. " + _IGNORE_EN,
    ),
    "restore_account": _Text(
        "восстановление аккаунта",
        "account restore",
        "Код для восстановления аккаунта: {code}\nКод действует {ttl} мин. " + _IGNORE_RU,
        "Your account restore code: {code}\nIt is valid for {ttl} minutes. " + _IGNORE_EN,
    ),
}

_NOTICES: dict[str, _Text] = {
    "account_exists": _Text(
        "уведомление об аккаунте",
        "account notice",
        "Кто-то попытался зарегистрироваться с этим адресом, но аккаунт уже существует. "
        "Если это были вы, войдите или сбросьте пароль в приложении. " + _IGNORE_RU,
        "Someone tried to register with this address, but an account already exists. "
        "If it was you, sign in or reset your password in the app. " + _IGNORE_EN,
    ),
    "deletion_requested": _Text(
        "удаление аккаунта",
        "account deletion",
        "Запрошено удаление аккаунта. Данные будут стёрты не позднее {when}. "
        "До этого срока аккаунт можно восстановить, войдя в приложение. " + _CHANGE_RU,
        "Deletion of your account was requested. Its data will be erased by {when}. "
        "Until then you can restore the account by signing in to the app. " + _CHANGE_EN,
    ),
    "account_restored": _Text(
        "аккаунт восстановлен",
        "account restored",
        "Ваш аккаунт восстановлен, удаление отменено. " + _CHANGE_RU,
        "Your account was restored and its deletion cancelled. " + _CHANGE_EN,
    ),
    "account_pending_deletion": _Text(
        "аккаунт ожидает удаления",
        "account pending deletion",
        "Кто-то попытался зарегистрироваться с этим адресом, но аккаунт ожидает удаления "
        "(данные будут стёрты не позднее {when}). Чтобы сохранить аккаунт, "
        "войдите в приложение и восстановите его. " + _IGNORE_RU,
        "Someone tried to register with this address, but the account is pending deletion "
        "(its data will be erased by {when}). To keep it, sign in to the app and restore it. "
        + _IGNORE_EN,
    ),
}


def _format_instant(value: datetime | None) -> str:
    if value is None:
        return "-"
    return value.astimezone(UTC).strftime("%Y-%m-%d %H:%M UTC")


def render(
    kind: EmailKind,
    *,
    code: str | None,
    ttl_minutes: int,
    erase_after: datetime | None = None,
) -> tuple[str, str]:
    """``(subject, body)`` of one mail; codes only for the code kinds, dates for deletion."""
    if kind in _CODE_KINDS:
        if code is None:
            raise ValueError(f"{kind} needs a code")
        text = _CODE_KINDS[kind]
    else:
        text = _NOTICES[kind]
    values = {"code": code or "", "ttl": ttl_minutes, "when": _format_instant(erase_after)}
    subject = f"PillPal: {text.subject_ru} / {text.subject_en}"
    body = text.body_ru.format(**values) + _SEPARATOR + text.body_en.format(**values)
    return subject, body
