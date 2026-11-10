"""StoreKit 2 JWS verification (ADR 0018 section 6): each check fails on its own.

Pure tests: a generated chain stands in for Apple's, so nothing here needs a database.
"""

from __future__ import annotations

import base64
import json
import uuid
from datetime import timedelta
from typing import Any

import pytest

from app.payments.base import InvalidPurchase
from app.payments.storekit import StoreKitVerifier
from tests.payments_helpers import (
    BUNDLE_ID,
    INTERMEDIATE_OID,
    NOW,
    ORIGINAL_ID,
    PRODUCT_ID,
    PRODUCTS,
    Chain,
    b64url,
    make_chain,
    millis,
    sign,
    transaction,
)

TOKEN = uuid.UUID("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")


@pytest.fixture(scope="module")
def chain() -> Chain:
    return make_chain()


def verifier(chain: Chain, **overrides: Any) -> StoreKitVerifier:
    values: dict[str, Any] = {
        "root_der": chain.root_der,
        "bundle_id": BUNDLE_ID,
        "products": PRODUCTS,
        "allow_sandbox": False,
    } | overrides
    return StoreKitVerifier(**values)


def reason(chain: Chain, signed: str, **overrides: Any) -> str:
    with pytest.raises(InvalidPurchase) as caught:
        verifier(chain, **overrides).verify(signed, account_token=TOKEN, now=NOW)
    return caught.value.reason


def test_a_valid_transaction_is_accepted(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN))
    result = verifier(chain).verify(signed, account_token=TOKEN, now=NOW)
    assert result.store == "app_store"
    assert result.product_id == PRODUCT_ID
    assert result.product_kind == "remove_ads"
    assert result.original_transaction_id == ORIGINAL_ID
    assert result.environment == "production"
    assert result.purchased_at == NOW - timedelta(minutes=5)


def test_the_chain_without_the_root_is_accepted_too(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN), x5c=chain.x5c(with_root=False))
    assert verifier(chain).verify(signed, account_token=TOKEN, now=NOW).product_id == PRODUCT_ID


def test_a_chain_to_another_root_is_refused(chain: Chain) -> None:
    other = make_chain()
    assert reason(chain, sign(other, transaction(TOKEN))) == "bad_chain"


def test_an_embedded_root_that_is_not_the_pinned_one_is_refused(chain: Chain) -> None:
    other = make_chain()
    x5c = chain.x5c(with_root=False) + other.x5c()[2:]
    assert reason(chain, sign(chain, transaction(TOKEN), x5c=x5c)) == "bad_chain"


def test_a_leaf_without_the_apple_marker_is_refused() -> None:
    chain = make_chain(leaf_marker=None)
    assert reason(chain, sign(chain, transaction(TOKEN))) == "bad_chain"


def test_a_leaf_with_the_intermediate_marker_only_is_refused() -> None:
    chain = make_chain(leaf_marker=INTERMEDIATE_OID)
    assert reason(chain, sign(chain, transaction(TOKEN))) == "bad_chain"


def test_an_intermediate_without_the_apple_marker_is_refused() -> None:
    chain = make_chain(intermediate_marker=None)
    assert reason(chain, sign(chain, transaction(TOKEN))) == "bad_chain"


def test_an_intermediate_that_is_not_a_ca_is_refused() -> None:
    chain = make_chain(intermediate_is_ca=False)
    assert reason(chain, sign(chain, transaction(TOKEN))) == "bad_chain"


def test_a_leaf_that_was_not_issued_by_the_intermediate_is_refused(chain: Chain) -> None:
    stranger = make_chain()
    x5c = [stranger.x5c()[0], chain.x5c()[1], chain.x5c()[2]]
    assert reason(chain, sign(stranger, transaction(TOKEN), x5c=x5c)) == "bad_chain"


def test_a_leaf_that_was_not_valid_when_the_transaction_was_signed_is_refused() -> None:
    chain = make_chain(leaf_not_after=NOW - timedelta(days=2))
    assert reason(chain, sign(chain, transaction(TOKEN))) == "bad_chain"


def test_a_leaf_that_expired_after_signing_still_verifies_the_old_transaction() -> None:
    chain = make_chain(leaf_not_after=NOW - timedelta(minutes=1))
    signed = sign(chain, transaction(TOKEN, signedDate=millis(NOW - timedelta(days=30))))
    assert verifier(chain).verify(signed, account_token=TOKEN, now=NOW).product_id == PRODUCT_ID


def test_a_signed_date_in_the_future_is_refused(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, signedDate=millis(NOW + timedelta(hours=1))))
    assert reason(chain, signed) == "malformed"


def test_a_missing_signed_date_is_refused(chain: Chain) -> None:
    assert reason(chain, sign(chain, transaction(TOKEN, drop=("signedDate",)))) == "malformed"


def test_a_signature_by_another_key_is_refused(chain: Chain) -> None:
    stranger = make_chain()
    signed = sign(chain, transaction(TOKEN), key=stranger.leaf_key)
    assert reason(chain, signed) == "bad_signature"


def test_a_tampered_payload_is_refused(chain: Chain) -> None:
    head, _, signature = sign(chain, transaction(TOKEN)).split(".")
    forged = b64url(json.dumps(transaction(TOKEN, productId="other")).encode())
    assert reason(chain, f"{head}.{forged}.{signature}") == "bad_signature"


@pytest.mark.parametrize("alg", ["none", "HS256", "ES384", "RS256", ""])
def test_only_es256_is_accepted(chain: Chain, alg: str) -> None:
    assert reason(chain, sign(chain, transaction(TOKEN), alg=alg)) == "malformed"


def test_a_signature_of_the_wrong_length_is_refused(chain: Chain) -> None:
    head, body, _ = sign(chain, transaction(TOKEN)).split(".")
    short = b64url(b"\x01" * 63)
    assert reason(chain, f"{head}.{body}.{short}") == "malformed"


@pytest.mark.parametrize(
    "garbage",
    ["", "a", "a.b", "a.b.c.d", "...", "not a jws at all", "e30.e30.e30", "ж.ж.ж"],
)
def test_garbage_is_malformed_not_an_error(chain: Chain, garbage: str) -> None:
    assert reason(chain, garbage) == "malformed"


def test_a_header_without_a_chain_is_refused(chain: Chain) -> None:
    assert reason(chain, sign(chain, transaction(TOKEN), x5c=[])) == "bad_chain"


def test_a_chain_of_junk_certificates_is_refused(chain: Chain) -> None:
    junk = base64.b64encode(b"not a certificate").decode()
    assert reason(chain, sign(chain, transaction(TOKEN), x5c=[junk, junk])) == "bad_chain"


def test_an_overlong_chain_is_refused(chain: Chain) -> None:
    x5c = chain.x5c() + chain.x5c()
    assert reason(chain, sign(chain, transaction(TOKEN), x5c=x5c)) == "bad_chain"


def test_another_bundle_is_refused(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, bundleId="com.example.other"))
    assert reason(chain, signed) == "bad_bundle"


def test_a_product_outside_the_allowlist_is_refused(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, productId="ru.pillpal.test.unknown"))
    assert reason(chain, signed) == "bad_product"


@pytest.mark.parametrize("kind", ["Consumable", "Auto-Renewable Subscription", "Non-Renewing", ""])
def test_only_a_non_consumable_is_accepted(chain: Chain, kind: str) -> None:
    assert reason(chain, sign(chain, transaction(TOKEN, type=kind))) == "bad_type"


def test_a_missing_type_is_refused(chain: Chain) -> None:
    assert reason(chain, sign(chain, transaction(TOKEN, drop=("type",)))) == "bad_type"


def test_a_family_shared_purchase_is_refused(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, inAppOwnershipType="FAMILY_SHARED"))
    assert reason(chain, signed) == "family_shared"


def test_a_missing_ownership_type_is_refused(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, drop=("inAppOwnershipType",)))
    assert reason(chain, signed) == "malformed"


@pytest.mark.parametrize("environment", ["Xcode", "LocalTesting", "", "production"])
def test_environments_other_than_production_and_sandbox_are_refused(
    chain: Chain, environment: str
) -> None:
    signed = sign(chain, transaction(TOKEN, environment=environment))
    assert reason(chain, signed, allow_sandbox=True) == "bad_environment"


def test_sandbox_is_refused_unless_allowed(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, environment="Sandbox"))
    assert reason(chain, signed) == "bad_environment"


def test_sandbox_is_accepted_when_allowed(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, environment="Sandbox"))
    result = verifier(chain, allow_sandbox=True).verify(signed, account_token=TOKEN, now=NOW)
    assert result.environment == "sandbox"


def test_a_missing_account_token_is_refused(chain: Chain) -> None:
    assert reason(chain, sign(chain, transaction(None))) == "bad_account_token"


def test_another_accounts_token_is_refused(chain: Chain) -> None:
    assert reason(chain, sign(chain, transaction(uuid.uuid4()))) == "bad_account_token"


def test_a_token_that_is_not_a_uuid_is_refused(chain: Chain) -> None:
    assert reason(chain, sign(chain, transaction("not-a-uuid"))) == "bad_account_token"


def test_the_token_is_compared_as_a_uuid_not_as_text(chain: Chain) -> None:
    signed = sign(chain, transaction(str(TOKEN).upper()))
    assert verifier(chain).verify(signed, account_token=TOKEN, now=NOW).product_id == PRODUCT_ID


def test_a_revoked_transaction_is_refused(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, revocationDate=millis(NOW - timedelta(days=1))))
    assert reason(chain, signed) == "revoked"


def test_a_revocation_reason_without_a_date_is_refused_as_well(chain: Chain) -> None:
    assert reason(chain, sign(chain, transaction(TOKEN, revocationReason=0))) == "revoked"


@pytest.mark.parametrize("drop", ["originalTransactionId", "productId", "purchaseDate"])
def test_a_missing_required_field_is_refused(chain: Chain, drop: str) -> None:
    signed = sign(chain, transaction(TOKEN, drop=(drop,)))
    assert reason(chain, signed) in {"bad_product", "malformed"}


@pytest.mark.parametrize("original", ["", " ", "x" * 256, 123])
def test_a_bad_original_transaction_id_is_refused(chain: Chain, original: Any) -> None:
    signed = sign(chain, transaction(TOKEN, originalTransactionId=original))
    assert reason(chain, signed) == "malformed"


def test_the_error_never_holds_the_transaction(chain: Chain) -> None:
    signed = sign(chain, transaction(TOKEN, bundleId="secret-bundle-value"))
    with pytest.raises(InvalidPurchase) as caught:
        verifier(chain).verify(signed, account_token=TOKEN, now=NOW)
    assert "secret-bundle-value" not in str(caught.value)
    assert signed not in repr(caught.value)
