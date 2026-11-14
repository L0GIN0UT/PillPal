"""The inviter's masked e-mail in an invite preview (ADR 0020 section 3)."""

from __future__ import annotations

import pytest

from app.domain.email_mask import PUBLIC_MAIL_DOMAINS, mask_email


@pytest.mark.parametrize(
    ("email", "masked"),
    [
        # A public provider keeps its domain; the local part keeps one character.
        ("ivan@mail.ru", "i***@mail.ru"),
        ("Synthetic.User+tag@Gmail.COM", "S***@Gmail.COM"),
        ("  xyz@yandex.ru  ", "x***@yandex.ru"),
        ("abc@proton.me", "a***@proton.me"),
        # A local part of one or two characters is masked whole.
        ("a@mail.ru", "***@mail.ru"),
        ("ab@gmail.com", "***@gmail.com"),
        # Any other domain is masked too, down to its first character and the TLD.
        ("ivan@ivanov.family", "i***@i***.family"),
        ("тест@пример.рф", "т***@п***.рф"),
        ("user@mail.example.com", "u***@m***.com"),
        ("ab@example.org", "***@e***.org"),
        ("user@localhost", "u***@l***"),
        # The last "@" splits: a quoted local part may contain one.
        ('"a@b"@example.com', '"***@e***.com'),
    ],
)
def test_masks_the_local_part_and_private_domains(email: str, masked: str) -> None:
    assert mask_email(email) == masked


@pytest.mark.parametrize("email", ["", "no-at-sign", "@example.com", "user@"])
def test_a_malformed_address_reveals_nothing(email: str) -> None:
    assert mask_email(email) == "***"


def test_the_public_provider_list_is_the_documented_one() -> None:
    assert sorted(PUBLIC_MAIL_DOMAINS) == sorted(
        [
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
        ]
    )
