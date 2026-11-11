"""Mail copy as structured fields, so the text and the HTML parts are built from the same strings.

Privacy (``.claude/rules/privacy.md`` 1): a mail says what happened to the *account*, never what
is in it - no medication, schedule or dose wording. Placeholders: ``{ttl}`` (minutes), ``{when}``
(erase date), ``{provider}`` (a name from :data:`PROVIDER_NAMES`); the code is never in a field.
"""

from __future__ import annotations

from typing import NamedTuple

IGNORE_RU = "Если это были не вы, просто проигнорируйте это письмо."
IGNORE_EN = "If this was not you, ignore this email."
CHANGE_RU = "Если это были не вы, смените пароль."
CHANGE_EN = "If this was not you, change your password."
IDENTITY_RU = "Если это были не вы, удалите этот способ входа в настройках и сбросьте пароль."
IDENTITY_EN = "If this was not you, remove this sign-in method in Settings and reset your password."

# What the notices call each provider (a fixed list: nothing the user or a provider typed).
PROVIDER_NAMES = {
    "apple": "Apple",
    "google": "Google",
    "vk_id": "VK ID",
    "yandex_id": "Yandex ID",
}


class LangCopy(NamedTuple):
    """One language of one mail. Code kinds: ``lead`` ends with a colon and the code follows it,
    ``ttl`` is the validity line. Notices: ``lead`` is the message, ``ttl`` is ``None``.
    ``tail`` is what to do if the reader did not cause this."""

    lead: str
    tail: str
    ttl: str | None = None


class KindCopy(NamedTuple):
    subject_ru: str
    subject_en: str
    ru: LangCopy
    en: LangCopy


_TTL_RU = "Код действует {ttl} мин."
_TTL_EN = "It is valid for {ttl} minutes."

CODE_KINDS: dict[str, KindCopy] = {
    "verify_email": KindCopy(
        "подтверждение e-mail",
        "e-mail confirmation",
        LangCopy("Код подтверждения e-mail:", IGNORE_RU, _TTL_RU),
        LangCopy("Your email confirmation code:", IGNORE_EN, _TTL_EN),
    ),
    "password_reset": KindCopy(
        "сброс пароля",
        "password reset",
        LangCopy("Код для сброса пароля:", IGNORE_RU, _TTL_RU),
        LangCopy("Your password reset code:", IGNORE_EN, _TTL_EN),
    ),
    "restore_account": KindCopy(
        "восстановление аккаунта",
        "account restore",
        LangCopy("Код для восстановления аккаунта:", IGNORE_RU, _TTL_RU),
        LangCopy("Your account restore code:", IGNORE_EN, _TTL_EN),
    ),
}

NOTICES: dict[str, KindCopy] = {
    "account_exists": KindCopy(
        "уведомление об аккаунте",
        "account notice",
        LangCopy(
            "Кто-то попытался зарегистрироваться с этим адресом, но аккаунт уже существует. "
            "Если это были вы, войдите или сбросьте пароль в приложении.",
            IGNORE_RU,
        ),
        LangCopy(
            "Someone tried to register with this address, but an account already exists. "
            "If it was you, sign in or reset your password in the app.",
            IGNORE_EN,
        ),
    ),
    "deletion_requested": KindCopy(
        "удаление аккаунта",
        "account deletion",
        LangCopy(
            "Запрошено удаление аккаунта. Данные будут стёрты не позднее {when}. "
            "До этого срока аккаунт можно восстановить, войдя в приложение.",
            CHANGE_RU,
        ),
        LangCopy(
            "Deletion of your account was requested. Its data will be erased by {when}. "
            "Until then you can restore the account by signing in to the app.",
            CHANGE_EN,
        ),
    ),
    "account_restored": KindCopy(
        "аккаунт восстановлен",
        "account restored",
        LangCopy("Ваш аккаунт восстановлен, удаление отменено.", CHANGE_RU),
        LangCopy("Your account was restored and its deletion cancelled.", CHANGE_EN),
    ),
    "account_pending_deletion": KindCopy(
        "аккаунт ожидает удаления",
        "account pending deletion",
        LangCopy(
            "Кто-то попытался зарегистрироваться с этим адресом, но аккаунт ожидает удаления "
            "(данные будут стёрты не позднее {when}). Чтобы сохранить аккаунт, "
            "войдите в приложение и восстановите его.",
            IGNORE_RU,
        ),
        LangCopy(
            "Someone tried to register with this address, but the account is pending deletion "
            "(its data will be erased by {when}). To keep it, sign in to the app and restore it.",
            IGNORE_EN,
        ),
    ),
    "oauth_not_linked": KindCopy(
        "аккаунт создан через вход с провайдером",
        "account started with a sign-in provider",
        LangCopy(
            "С этим адресом начато создание аккаунта через вход с внешним провайдером, но "
            "провайдер не был привязан. Чтобы войти, задайте пароль через «Забыли пароль» "
            "в приложении.",
            IGNORE_RU,
        ),
        LangCopy(
            "An account was started with this address through a sign-in provider, but no "
            'provider was linked. To sign in, set a password with "Forgot password" in the app.',
            IGNORE_EN,
        ),
    ),
    "identity_linked": KindCopy(
        "добавлен способ входа",
        "sign-in method added",
        LangCopy("К вашему аккаунту добавлен вход через {provider}.", IDENTITY_RU),
        LangCopy("Sign-in with {provider} was added to your account.", IDENTITY_EN),
    ),
    "identity_unlinked": KindCopy(
        "удалён способ входа",
        "sign-in method removed",
        LangCopy("Из вашего аккаунта удалён вход через {provider}.", IDENTITY_RU),
        LangCopy("Sign-in with {provider} was removed from your account.", IDENTITY_EN),
    ),
    "export_requested": KindCopy(
        "запрос выгрузки данных",
        "data export requested",
        LangCopy(
            "Запрошена выгрузка данных вашего аккаунта. Она будет доступна в приложении "
            "в течение суток, скачать её можно один раз.",
            CHANGE_RU,
        ),
        LangCopy(
            "An export of your account data was requested. It will be available in the app "
            "for one day and can be downloaded once.",
            CHANGE_EN,
        ),
    ),
}
