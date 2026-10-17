"""Mail settings, the staging environment and the choice of the sender at startup."""

from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.email import InMemoryEmailSender, LoggingEmailSender
from app.email_smtp import SmtpEmailSender
from app.main import create_app
from tests.conftest import make_settings

SMTP = {
    "email_backend": "smtp",
    "smtp_host": "smtp.example.org",
    "smtp_from": "PillPal <noreply@example.org>",
    "smtp_username": "mailer",
    "smtp_password": "secret-pass",
}


def smtp_settings(**overrides: object) -> Settings:
    return make_settings(**{**SMTP, **overrides})


def test_default_backend_is_log() -> None:
    assert make_settings().email_backend == "log"


@pytest.mark.parametrize("missing", ["smtp_host", "smtp_from"])
def test_smtp_needs_host_and_sender(missing: str) -> None:
    with pytest.raises(ValidationError, match=missing.upper()):
        smtp_settings(**{missing: None})


def test_smtp_sender_must_be_an_address() -> None:
    with pytest.raises(ValidationError, match="SMTP_FROM"):
        smtp_settings(smtp_from="not an address")


@pytest.mark.parametrize(("security", "port"), [("ssl", 465), ("starttls", 587)])
def test_port_defaults_follow_the_security_mode(security: str, port: int) -> None:
    assert smtp_settings(smtp_security=security).smtp_port == port
    assert smtp_settings(smtp_security=security, smtp_port=2525).smtp_port == 2525


def test_default_security_is_implicit_tls() -> None:
    assert smtp_settings().smtp_security == "ssl"


def test_password_comes_from_a_file(tmp_path: Path) -> None:
    secret = tmp_path / "smtp_password"
    secret.write_text("from-file\n", encoding="utf-8")
    settings = smtp_settings(smtp_password=None, smtp_password_file=str(secret))
    assert settings.smtp_password is not None
    assert settings.smtp_password.get_secret_value() == "from-file"
    assert "from-file" not in repr(settings)


def test_password_and_file_are_exclusive(tmp_path: Path) -> None:
    secret = tmp_path / "smtp_password"
    secret.write_text("x", encoding="utf-8")
    with pytest.raises(ValidationError, match="SMTP_PASSWORD and SMTP_PASSWORD_FILE"):
        smtp_settings(smtp_password_file=str(secret))


def test_username_needs_a_password_and_back() -> None:
    with pytest.raises(ValidationError, match="SMTP_PASSWORD"):
        smtp_settings(smtp_password=None)
    with pytest.raises(ValidationError, match="SMTP_USERNAME"):
        smtp_settings(smtp_username=None)


def test_blank_credentials_mean_unset() -> None:
    settings = smtp_settings(smtp_username="", smtp_password="  ")
    assert settings.smtp_username is None
    assert settings.smtp_password is None


def test_staging_is_a_known_environment_with_prod_safety() -> None:
    assert make_settings(environment="staging").environment == "staging"
    with pytest.raises(ValidationError, match="LOG_EMAIL_CODES"):
        make_settings(environment="staging", log_email_codes=True)


def test_staging_rejects_a_partial_push_provider() -> None:
    with pytest.raises(ValidationError, match="FCM"):
        make_settings(environment="staging", fcm_project_id="demo-project")


@pytest.mark.parametrize("environment", ["prod", "staging"])
@pytest.mark.parametrize("backend", ["log", "memory"])
def test_real_environments_refuse_a_non_smtp_backend(environment: str, backend: str) -> None:
    with pytest.raises(RuntimeError, match="SMTP"):
        create_app(make_settings(environment=environment, email_backend=backend))


def test_staging_starts_with_smtp() -> None:
    app = create_app(smtp_settings(environment="staging"))
    assert isinstance(app.state.email_sender, SmtpEmailSender)


def test_backend_selects_the_sender() -> None:
    assert isinstance(create_app(make_settings()).state.email_sender, LoggingEmailSender)
    memory = create_app(make_settings(email_backend="memory")).state.email_sender
    assert isinstance(memory, InMemoryEmailSender)
    assert isinstance(create_app(smtp_settings()).state.email_sender, SmtpEmailSender)


def test_injected_sender_wins() -> None:
    fake = InMemoryEmailSender()
    app = create_app(make_settings(environment="staging"), email_sender=fake)
    assert app.state.email_sender is fake
