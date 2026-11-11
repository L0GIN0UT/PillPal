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
RESET_RU = "Если это были не вы, сбросьте пароль через «Забыли пароль» в приложении."
RESET_EN = 'If this was not you, reset your password with "Forgot password" in the app.'
FOOTER_RU = "Письмо отправлено автоматически, отвечать на него не нужно."
FOOTER_EN = "This message was sent automatically; no reply is needed."

# What the notices call each provider (a fixed list: nothing the user or a provider typed).
PROVIDER_NAMES = {
    "apple": "Apple",
    "google": "Google",
    "vk_id": "VK ID",
    "yandex_id": "Yandex ID",
}


class LangCopy(NamedTuple):
    """One language of one mail. ``heading`` titles it. Code kinds: ``intro`` says what the code
    is for and ``ttl`` is the validity line (the code itself is rendered between them).
    Notices: ``lead`` is the message. ``tail`` is what to do if the reader did not cause this."""

    heading: str
    tail: str
    lead: str = ""
    ttl: str | None = None
    intro: str | None = None


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
        LangCopy(
            "Код подтверждения",
            IGNORE_RU,
            ttl=_TTL_RU,
            intro="Введите этот код в приложении, чтобы подтвердить адрес и закончить регистрацию.",
        ),
        LangCopy(
            "Confirmation code",
            IGNORE_EN,
            ttl=_TTL_EN,
            intro="Enter this code in the app to confirm your address and finish signing up.",
        ),
    ),
    "password_reset": KindCopy(
        "сброс пароля",
        "password reset",
        LangCopy(
            "Код для сброса пароля",
            IGNORE_RU,
            ttl=_TTL_RU,
            intro="Введите этот код в приложении, чтобы задать новый пароль.",
        ),
        LangCopy(
            "Password reset code",
            IGNORE_EN,
            ttl=_TTL_EN,
            intro="Enter this code in the app to set a new password.",
        ),
    ),
    "password_change": KindCopy(
        "смена пароля",
        "password change",
        LangCopy(
            "Код для смены пароля",
            IGNORE_RU,
            ttl=_TTL_RU,
            intro="Введите этот код в приложении, чтобы подтвердить смену пароля.",
        ),
        LangCopy(
            "Password change code",
            IGNORE_EN,
            ttl=_TTL_EN,
            intro="Enter this code in the app to confirm the password change.",
        ),
    ),
    "restore_account": KindCopy(
        "восстановление аккаунта",
        "account restore",
        LangCopy(
            "Код для восстановления аккаунта",
            IGNORE_RU,
            ttl=_TTL_RU,
            intro="Введите этот код в приложении, чтобы восстановить аккаунт.",
        ),
        LangCopy(
            "Account restore code",
            IGNORE_EN,
            ttl=_TTL_EN,
            intro="Enter this code in the app to restore your account.",
        ),
    ),
}

NOTICES: dict[str, KindCopy] = {
    "account_exists": KindCopy(
        "уведомление об аккаунте",
        "account notice",
        LangCopy(
            "Аккаунт уже существует",
            IGNORE_RU,
            lead="Кто-то попытался зарегистрироваться с этим адресом, но аккаунт уже существует. "
            "Если это были вы, войдите или сбросьте пароль в приложении.",
        ),
        LangCopy(
            "Account already exists",
            IGNORE_EN,
            lead="Someone tried to register with this address, but an account already exists. "
            "If it was you, sign in or reset your password in the app.",
        ),
    ),
    "deletion_requested": KindCopy(
        "удаление аккаунта",
        "account deletion",
        LangCopy(
            "Удаление аккаунта",
            CHANGE_RU,
            lead="Запрошено удаление аккаунта. Данные будут стёрты не позднее {when}. "
            "До этого срока аккаунт можно восстановить, войдя в приложение.",
        ),
        LangCopy(
            "Account deletion",
            CHANGE_EN,
            lead="Deletion of your account was requested. Its data will be erased by {when}. "
            "Until then you can restore the account by signing in to the app.",
        ),
    ),
    "account_restored": KindCopy(
        "аккаунт восстановлен",
        "account restored",
        LangCopy(
            "Аккаунт восстановлен",
            CHANGE_RU,
            lead="Ваш аккаунт восстановлен, удаление отменено.",
        ),
        LangCopy(
            "Account restored",
            CHANGE_EN,
            lead="Your account was restored and its deletion cancelled.",
        ),
    ),
    "account_pending_deletion": KindCopy(
        "аккаунт ожидает удаления",
        "account pending deletion",
        LangCopy(
            "Аккаунт ожидает удаления",
            IGNORE_RU,
            lead="Кто-то попытался зарегистрироваться с этим адресом, но аккаунт ожидает удаления "
            "(данные будут стёрты не позднее {when}). Чтобы сохранить аккаунт, "
            "войдите в приложение и восстановите его.",
        ),
        LangCopy(
            "Account pending deletion",
            IGNORE_EN,
            lead="Someone tried to register with this address, but the account is pending "
            "deletion (its data will be erased by {when}). To keep it, sign in to the app and "
            "restore it.",
        ),
    ),
    "oauth_not_linked": KindCopy(
        "аккаунт создан через вход с провайдером",
        "account started with a sign-in provider",
        LangCopy(
            "Вход через провайдера не привязан",
            IGNORE_RU,
            lead="С этим адресом начато создание аккаунта через вход с внешним провайдером, но "
            "провайдер не был привязан. Чтобы войти, задайте пароль через «Забыли пароль» "
            "в приложении.",
        ),
        LangCopy(
            "Sign-in provider not linked",
            IGNORE_EN,
            lead="An account was started with this address through a sign-in provider, but no "
            'provider was linked. To sign in, set a password with "Forgot password" in the app.',
        ),
    ),
    "identity_linked": KindCopy(
        "добавлен способ входа",
        "sign-in method added",
        LangCopy(
            "Добавлен способ входа",
            IDENTITY_RU,
            lead="К вашему аккаунту добавлен вход через {provider}.",
        ),
        LangCopy(
            "Sign-in method added",
            IDENTITY_EN,
            lead="Sign-in with {provider} was added to your account.",
        ),
    ),
    "identity_unlinked": KindCopy(
        "удалён способ входа",
        "sign-in method removed",
        LangCopy(
            "Удалён способ входа",
            IDENTITY_RU,
            lead="Из вашего аккаунта удалён вход через {provider}.",
        ),
        LangCopy(
            "Sign-in method removed",
            IDENTITY_EN,
            lead="Sign-in with {provider} was removed from your account.",
        ),
    ),
    "password_changed": KindCopy(
        "пароль изменён",
        "password changed",
        LangCopy(
            "Пароль изменён",
            RESET_RU,
            lead="Пароль вашего аккаунта был изменён.",
        ),
        LangCopy(
            "Password changed",
            RESET_EN,
            lead="The password of your account was changed.",
        ),
    ),
    "export_requested": KindCopy(
        "запрос выгрузки данных",
        "data export requested",
        LangCopy(
            "Запрос выгрузки данных",
            CHANGE_RU,
            lead="Запрошена выгрузка данных вашего аккаунта. Она будет доступна в приложении "
            "в течение суток, скачать её можно один раз.",
        ),
        LangCopy(
            "Data export requested",
            CHANGE_EN,
            lead="An export of your account data was requested. It will be available in the app "
            "for one day and can be downloaded once.",
        ),
    ),
}
