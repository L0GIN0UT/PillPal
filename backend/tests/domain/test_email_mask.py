"""The inviter's masked e-mail in an invite preview (ADR 0020 section 3)."""

from __future__ import annotations

import pytest

from app.domain.email_mask import mask_email


@pytest.mark.parametrize(
    ("email", "masked"),
    [
        ("ivan@mail.ru", "i***@mail.ru"),
        ("a@example.com", "a***@example.com"),
        ("Synthetic.User+tag@Example.COM", "S***@Example.COM"),
        ("тест@пример.рф", "т***@пример.рф"),
        ("  x@y.org  ", "x***@y.org"),
        # The last "@" splits: a quoted local part may contain one.
        ('"a@b"@example.com', '"***@example.com'),
    ],
)
def test_keeps_the_first_character_and_the_domain(email: str, masked: str) -> None:
    assert mask_email(email) == masked


@pytest.mark.parametrize("email", ["", "no-at-sign", "@example.com", "user@"])
def test_a_malformed_address_reveals_nothing(email: str) -> None:
    assert mask_email(email) == "***"
