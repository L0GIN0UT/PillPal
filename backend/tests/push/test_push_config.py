"""Push settings: optional providers, ``*_FILE`` secrets, prod completeness, EU without RuStore."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from tests.conftest import make_settings

FCM_JSON = json.dumps(
    {"client_email": "svc@example-project.iam.gserviceaccount.com", "private_key": "pem"}
)
FCM = {"fcm_project_id": "example-project", "fcm_service_account_json": FCM_JSON}
APNS = {
    "apns_team_id": "ABCDE12345",
    "apns_key_id": "KEY1234567",
    "apns_private_key": "-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----",
    "apns_topic": "app.example.pillpal",
}
RUSTORE = {"rustore_project_id": "proj-1", "rustore_service_token": "service-token"}


def test_every_provider_is_optional() -> None:
    settings = make_settings()
    assert settings.fcm_service_account_json is None
    assert settings.push_max_attempts == 5
    assert settings.push_stale_after_seconds == 7200
    assert settings.push_max_tokens_per_user == 10


def test_secrets_are_not_printed() -> None:
    settings = make_settings(**FCM, **APNS, **RUSTORE)
    text = repr(settings) + str(settings.model_dump())
    for secret in ("service-token", "BEGIN PRIVATE KEY", "svc@example-project", ':"pem"'):
        assert secret not in text


@pytest.mark.parametrize("field", ["rustore_project_id", "rustore_service_token"])
@pytest.mark.parametrize("environment", ["dev", "test", "prod"])
def test_eu_with_any_rustore_setting_fails_startup(field: str, environment: str) -> None:
    with pytest.raises(ValidationError, match="RUSTORE"):
        make_settings(region="eu", environment=environment, **{field: RUSTORE[field]})


def test_eu_with_rustore_token_file_fails_startup(tmp_path: Path) -> None:
    token = tmp_path / "rustore"
    token.write_text("service-token")
    with pytest.raises(ValidationError, match="RUSTORE"):
        make_settings(region="eu", rustore_service_token_file=str(token))


def test_ru_accepts_rustore() -> None:
    assert make_settings(region="ru", **RUSTORE).rustore_project_id == "proj-1"


def test_eu_accepts_fcm_and_apns() -> None:
    settings = make_settings(region="eu", **FCM, **APNS)
    assert settings.apns_topic == "app.example.pillpal"


@pytest.mark.parametrize(
    "partial",
    [
        {"fcm_project_id": "example-project"},
        {"fcm_service_account_json": FCM_JSON},
        {"apns_team_id": "ABCDE12345", "apns_key_id": "KEY1234567"},
        {"rustore_project_id": "proj-1"},
        {"rustore_service_token": "service-token"},
    ],
)
def test_partially_configured_provider_fails_in_prod_only(partial: dict[str, str]) -> None:
    make_settings(environment="dev", **partial)  # treated as disabled
    with pytest.raises(ValidationError, match="partially configured"):
        make_settings(environment="prod", **partial)


def test_complete_providers_are_accepted_in_prod() -> None:
    settings = make_settings(environment="prod", **FCM, **APNS, **RUSTORE)
    assert settings.fcm_project_id == "example-project"


def test_prod_rejects_unparseable_fcm_service_account() -> None:
    with pytest.raises(ValidationError, match="FCM_SERVICE_ACCOUNT_JSON"):
        make_settings(
            environment="prod", fcm_project_id="p", fcm_service_account_json='{"nope": 1}'
        )


def test_secret_files_are_read_and_trimmed(tmp_path: Path) -> None:
    fcm = tmp_path / "fcm.json"
    fcm.write_text(FCM_JSON + "\n")
    key = tmp_path / "apns.p8"
    key.write_text(APNS["apns_private_key"] + "\n")
    token = tmp_path / "rustore"
    token.write_text("service-token\n")
    settings = make_settings(
        fcm_project_id="example-project",
        fcm_service_account_json_file=str(fcm),
        apns_team_id=APNS["apns_team_id"],
        apns_key_id=APNS["apns_key_id"],
        apns_topic=APNS["apns_topic"],
        apns_private_key_file=str(key),
        **{"rustore_project_id": "proj-1", "rustore_service_token_file": str(token)},
    )
    assert settings.fcm_service_account_json is not None
    assert settings.fcm_service_account_json.get_secret_value() == FCM_JSON
    assert settings.apns_private_key is not None
    assert settings.apns_private_key.get_secret_value() == APNS["apns_private_key"]
    assert settings.rustore_service_token is not None
    assert settings.rustore_service_token.get_secret_value() == "service-token"
    # Complete only thanks to the files: prod accepts it.
    make_settings(
        environment="prod", fcm_project_id="example-project", fcm_service_account_json_file=str(fcm)
    )


def test_value_and_file_together_are_ambiguous(tmp_path: Path) -> None:
    token = tmp_path / "rustore"
    token.write_text("from-file")
    with pytest.raises(ValidationError, match="RUSTORE_SERVICE_TOKEN"):
        make_settings(rustore_service_token="inline", rustore_service_token_file=str(token))


def test_unreadable_secret_file_fails_without_echoing_a_path_content(tmp_path: Path) -> None:
    with pytest.raises(ValidationError, match="APNS_PRIVATE_KEY_FILE"):
        make_settings(apns_private_key_file=str(tmp_path / "missing.p8"))


def test_push_numbers_are_validated() -> None:
    with pytest.raises(ValidationError):
        make_settings(push_max_attempts=0)
    with pytest.raises(ValidationError):
        make_settings(push_max_tokens_per_user=0)
