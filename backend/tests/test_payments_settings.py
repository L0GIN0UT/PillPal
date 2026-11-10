"""Payments settings and the stores of a region (ADR 0018 sections 6 and 7). Pure: no database."""

from __future__ import annotations

import base64
import hashlib
import uuid
from datetime import UTC, datetime
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes
from pydantic import ValidationError

from app.config import Settings
from app.payments.base import StoreUnavailable
from app.payments.registry import APPLE_ROOT_CERT_PATH, PaymentRegistry
from app.payments.storekit import StoreKitVerifier
from tests.conftest import EXPORT_KEY_1, make_settings

KEY_B64 = base64.b64encode(bytes((i * 5 + 1) % 256 for i in range(32))).decode()
ASCII_KEY_B64 = base64.b64encode(b"a" * 32).decode()
PRODUCTS = {"ru.pillpal.remove_ads": "remove_ads"}
# SHA-256 of Apple Root CA - G3 as published at apple.com/certificateauthority.
APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
STRICT_BASE = {
    "environment": "staging",
    "email_backend": "smtp",
    "smtp_host": "smtp.example.com",
    "smtp_from": "noreply@example.com",
}


def strict_payments(**overrides: object) -> Settings:
    values: dict[str, object] = (
        STRICT_BASE
        | {
            "feature_payments": True,
            "payments_app_account_key": KEY_B64,
            "payments_apple_bundle_id": "ru.pillpal.app",
            "payments_products": PRODUCTS,
        }
        | overrides
    )
    return make_settings(**values)


def test_payments_are_off_by_default_with_safe_limits() -> None:
    settings = make_settings()
    assert settings.feature_payments is False
    assert settings.payments_products == {}
    assert settings.payments_allow_sandbox is False
    assert settings.payments_apple_root_cert_path is None
    assert settings.payments_max_body_bytes == 16 * 1024
    assert settings.payments_key_bytes() is None


def test_the_account_key_must_be_32_base64_bytes_and_is_never_echoed() -> None:
    for bad in ("not base64!", base64.b64encode(b"short").decode()):
        with pytest.raises(ValidationError) as caught:
            make_settings(payments_app_account_key=bad)
        assert bad not in str(caught.value)
    assert len(make_settings(payments_app_account_key=KEY_B64).payments_key_bytes() or b"") == 32


def test_a_blank_account_key_is_unset() -> None:
    assert make_settings(payments_app_account_key="  ").payments_app_account_key is None


def test_the_account_key_must_differ_from_the_other_secrets() -> None:
    for clash in (
        {"jwt_secret": KEY_B64},
        {"jwt_secret": "a" * 32, "payments_app_account_key": ASCII_KEY_B64},  # the key's bytes
        {"promo_code_hmac_key": KEY_B64},
        {"data_encryption_keys": {1: KEY_B64}, "data_encryption_key_id": 1},
    ):
        with pytest.raises(ValidationError, match="PAYMENTS_APP_ACCOUNT_KEY"):
            make_settings(**{"payments_app_account_key": KEY_B64} | clash)
    ok = make_settings(payments_app_account_key=KEY_B64, promo_code_hmac_key=ASCII_KEY_B64)
    assert ok.payments_app_account_key is not None


def test_an_export_key_that_equals_the_account_key_is_refused_whatever_the_order() -> None:
    with pytest.raises(ValidationError):
        make_settings(
            payments_app_account_key=EXPORT_KEY_1,
            data_encryption_keys={1: EXPORT_KEY_1},
            data_encryption_key_id=1,
        )


def test_the_sandbox_is_allowed_outside_prod_and_refused_in_prod() -> None:
    assert make_settings(payments_allow_sandbox=True).payments_allow_sandbox is True
    assert strict_payments(payments_allow_sandbox=True).payments_allow_sandbox is True
    with pytest.raises(ValidationError, match="PAYMENTS_ALLOW_SANDBOX"):
        make_settings(environment="prod", payments_allow_sandbox=True)


def test_a_root_override_is_refused_in_strict_environments(tmp_path: Path) -> None:
    root = tmp_path / "root.cer"
    root.write_bytes(b"x")
    assert make_settings(payments_apple_root_cert_path=str(root)).payments_apple_root_cert_path
    for environment in ("staging", "prod"):
        with pytest.raises(ValidationError, match="PAYMENTS_APPLE_ROOT_CERT_PATH"):
            make_settings(environment=environment, payments_apple_root_cert_path=str(root))


def test_soft_limits_need_payments_in_strict_environments() -> None:
    assert make_settings(feature_soft_limits=True).feature_soft_limits is True  # dev and test
    for environment in ("staging", "prod"):
        with pytest.raises(ValidationError, match="FEATURE_SOFT_LIMITS"):
            make_settings(**STRICT_BASE | {"environment": environment, "feature_soft_limits": True})
    both = strict_payments(feature_soft_limits=True)
    assert both.feature_soft_limits
    assert both.feature_payments


@pytest.mark.parametrize(
    "missing", ["payments_app_account_key", "payments_apple_bundle_id", "payments_products"]
)
def test_strict_payments_need_the_key_the_bundle_and_a_product(missing: str) -> None:
    empty: object = {} if missing == "payments_products" else None
    with pytest.raises(ValidationError, match="FEATURE_PAYMENTS"):
        strict_payments(**{missing: empty})


def test_dev_payments_may_start_unconfigured() -> None:
    assert make_settings(feature_payments=True).feature_payments is True


def test_a_product_must_map_to_a_known_kind() -> None:
    with pytest.raises(ValidationError, match="PAYMENTS_PRODUCTS"):
        make_settings(payments_products={"ru.pillpal.gold": "gold"})
    with pytest.raises(ValidationError, match="PAYMENTS_PRODUCTS"):
        make_settings(payments_products={"": "remove_ads"})


def test_products_are_read_from_json_in_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("REGION", "ru")
    monkeypatch.setenv("JWT_SECRET", "e" * 40)
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@db:5432/pillpal")
    monkeypatch.setenv("PAYMENTS_PRODUCTS", '{"ru.pillpal.remove_ads": "remove_ads"}')
    assert Settings().payments_products == PRODUCTS  # type: ignore[call-arg]


def test_the_bundle_id_must_look_like_one() -> None:
    with pytest.raises(ValidationError):
        make_settings(payments_apple_bundle_id="not a bundle")
    assert make_settings(payments_apple_bundle_id="ru.pillpal.app").payments_apple_bundle_id


def test_the_body_limit_is_bounded() -> None:
    for bad in (0, 100, 10_000_000):
        with pytest.raises(ValidationError):
            make_settings(payments_max_body_bytes=bad)


@pytest.mark.parametrize(
    ("region", "stores"),
    [("ru", ["rustore", "app_store"]), ("eu", ["app_store", "google_play"])],
)
def test_the_registry_serves_the_stores_of_the_region(region: str, stores: list[str]) -> None:
    registry = PaymentRegistry(make_settings(region=region))
    assert registry.stores == stores


@pytest.mark.parametrize(
    ("region", "store"), [("eu", "rustore"), ("ru", "google_play"), ("ru", "other")]
)
def test_any_other_store_region_pair_is_refused_at_startup(region: str, store: str) -> None:
    with pytest.raises(ValidationError, match="PAYMENTS_STORES"):
        make_settings(region=region, payments_stores=[store])


def test_a_subset_of_the_stores_of_the_region_is_allowed() -> None:
    registry = PaymentRegistry(make_settings(region="ru", payments_stores=["app_store"]))
    assert registry.stores == ["app_store"]
    assert registry.get("rustore") is None


@pytest.mark.parametrize(
    ("region", "store"), [("ru", "rustore"), ("eu", "google_play"), ("ru", "app_store")]
)
def test_stub_and_unconfigured_stores_are_unavailable_not_invalid(region: str, store: str) -> None:
    verifier = PaymentRegistry(make_settings(region=region)).get(store)
    assert verifier is not None
    assert verifier.store == store
    with pytest.raises(StoreUnavailable):
        verifier.verify("token", account_token=uuid.uuid4(), now=datetime.now(UTC))


def test_a_configured_app_store_gets_the_storekit_verifier() -> None:
    settings = make_settings(payments_apple_bundle_id="ru.pillpal.app", payments_products=PRODUCTS)
    assert isinstance(PaymentRegistry(settings).get("app_store"), StoreKitVerifier)


def test_the_pinned_apple_root_is_the_published_g3_certificate() -> None:
    der = APPLE_ROOT_CERT_PATH.read_bytes()
    cert = x509.load_der_x509_certificate(der)
    assert "Apple Root CA - G3" in cert.subject.rfc4514_string()
    assert hashlib.sha256(der).hexdigest() == APPLE_ROOT_G3_SHA256
    assert cert.fingerprint(hashes.SHA256()).hex() == APPLE_ROOT_G3_SHA256
