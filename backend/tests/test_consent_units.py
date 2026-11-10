"""Consent records (Phase 5.2a), no database: settings, registration validation, schemas."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.errors import AppError
from app.schemas.auth import RegisterRequest
from app.schemas.consents import ConsentIn
from app.services.consents import current_versions, validate_registration_consents
from tests.conftest import make_settings

BASELINE = [
    ConsentIn(kind="health_data", version=1),
    ConsentIn(kind="terms", version=1),
    ConsentIn(kind="privacy", version=1),
]


def test_defaults_are_version_one_and_registration_does_not_require_consents() -> None:
    settings = make_settings()
    assert settings.consent_versions_health_data == [1]
    assert settings.consent_versions_terms == [1]
    assert settings.consent_versions_privacy == [1]
    assert settings.consent_required_at_registration is False
    assert current_versions(settings) == {
        "health_data": 1,
        "terms": 1,
        "privacy": 1,
        "catalog_contribution": 1,
    }


def test_the_current_version_is_the_highest_known_one(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CONSENT_VERSIONS_TERMS", "1, 3,2")
    monkeypatch.setenv("CONSENT_VERSIONS_PRIVACY", "[2]")
    settings = make_settings()
    assert settings.consent_versions_terms == [1, 3, 2]
    assert current_versions(settings)["terms"] == 3
    assert current_versions(settings)["privacy"] == 2


@pytest.mark.parametrize("value", ["", "0", "1,1", "1001", "-1", "[]"])
def test_bad_version_lists_are_refused(value: str, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CONSENT_VERSIONS_HEALTH_DATA", value)
    with pytest.raises(ValidationError, match="CONSENT_VERSIONS"):
        make_settings()


def test_prod_forces_consents_at_registration() -> None:
    assert make_settings(environment="prod").consent_required_at_registration is True
    assert (
        make_settings(
            environment="prod", consent_required_at_registration=False
        ).consent_required_at_registration
        is True
    )
    for environment in ("dev", "test", "staging"):
        assert make_settings(environment=environment).consent_required_at_registration is False
    assert make_settings(
        environment="staging", consent_required_at_registration=True
    ).consent_required_at_registration


def test_contribution_versions_must_fit_the_ledger() -> None:
    with pytest.raises(ValidationError, match="GTIN_LINK_CONSENT_VERSIONS"):
        make_settings(gtin_link_consent_versions=[1001])


def test_no_consents_are_fine_while_not_required() -> None:
    assert validate_registration_consents(make_settings(), None) == []


def test_missing_consents_are_refused_when_required() -> None:
    settings = make_settings(consent_required_at_registration=True)
    for given in (None, [], BASELINE[:2]):
        with pytest.raises(AppError) as info:
            validate_registration_consents(settings, given)
        assert (info.value.status_code, info.value.code) == (422, "consent_required")


def test_present_consents_are_validated_even_when_not_required() -> None:
    settings = make_settings()
    with pytest.raises(AppError) as info:
        validate_registration_consents(settings, [])
    assert info.value.code == "consent_required"
    with pytest.raises(AppError) as info:
        validate_registration_consents(settings, BASELINE[:1])
    assert info.value.code == "consent_required"


def test_an_old_known_version_is_not_the_current_one() -> None:
    settings = make_settings(consent_versions_terms=[1, 2])
    with pytest.raises(AppError) as info:
        validate_registration_consents(settings, BASELINE)
    assert info.value.code == "consent_required"


def test_an_unknown_version_is_refused_first() -> None:
    bad = [*BASELINE[:2], ConsentIn(kind="privacy", version=7)]
    with pytest.raises(AppError) as info:
        validate_registration_consents(make_settings(), bad)
    assert (info.value.status_code, info.value.code) == (422, "unsupported_consent_version")


def test_the_baseline_is_returned_in_order_and_the_contribution_is_validated_too() -> None:
    settings = make_settings()
    given = [*BASELINE, ConsentIn(kind="catalog_contribution", version=1)]
    assert validate_registration_consents(settings, given) == [
        ("health_data", 1),
        ("terms", 1),
        ("privacy", 1),
        ("catalog_contribution", 1),
    ]
    with pytest.raises(AppError) as info:
        validate_registration_consents(
            settings, [*BASELINE, ConsentIn(kind="catalog_contribution", version=9)]
        )
    assert info.value.code == "unsupported_consent_version"


def _register(**extra: object) -> RegisterRequest:
    return RegisterRequest.model_validate(
        {"email": "a@example.com", "password": "correct horse battery", "region": "ru", **extra}
    )


def test_register_request_consents_default_to_absent() -> None:
    assert _register().consents is None


@pytest.mark.parametrize(
    "consents",
    [
        [{"kind": "terms", "version": 1}, {"kind": "terms", "version": 1}],  # duplicate kind
        [{"kind": "ads", "version": 1}],
        [{"kind": "terms", "version": 0}],
        [{"kind": "terms", "version": 1001}],
        [{"kind": "terms", "version": "1"}],
        [{"kind": "terms", "version": 1, "extra": 1}],
        [{"kind": k, "version": 1} for k in ("terms", "privacy", "health_data")] * 2,
    ],
)
def test_register_request_refuses_malformed_consents(consents: list[dict[str, object]]) -> None:
    with pytest.raises(ValidationError):
        _register(consents=consents)
