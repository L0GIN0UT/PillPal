"""The re-auth form shared by deletion, export, link and unlink (ADR 0017 section 8)."""

from __future__ import annotations

from typing import Any

import pytest
from pydantic import ValidationError

from app.schemas.auth import DeleteAccountRequest
from app.schemas.exports import ExportRequest
from app.schemas.identities import LinkIdentityRequest
from app.schemas.reauth import ReauthProof

ASSERTION = {"provider": "vk_id", "platform": "android", "assertion": "x", "nonce": "n" * 24}


@pytest.mark.parametrize("model", [DeleteAccountRequest, ExportRequest, ReauthProof])
def test_the_password_form_is_accepted(model: type[ReauthProof]) -> None:
    assert model.model_validate({"password": "pw"}).password == "pw"


@pytest.mark.parametrize("model", [DeleteAccountRequest, ExportRequest, ReauthProof])
def test_the_assertion_form_is_accepted(model: type[ReauthProof]) -> None:
    parsed = model.model_validate({"reauth": ASSERTION})
    assert parsed.password is None
    assert parsed.reauth is not None
    assert parsed.reauth.provider == "vk_id"


@pytest.mark.parametrize("model", [DeleteAccountRequest, ExportRequest, ReauthProof])
@pytest.mark.parametrize(
    "body",
    [
        {},
        {"password": "pw", "reauth": ASSERTION},
        {"password": None},
        {"reauth": None},
        {"password": "p" * 129},
        {"reauth": {**ASSERTION, "provider": "github"}},
        {"reauth": {**ASSERTION, "extra": 1}},
        {"reauth": {**ASSERTION, "platform": "web"}},
        {"password": "pw", "unknown": 1},
    ],
)
def test_anything_but_exactly_one_form_is_refused(model: type[ReauthProof], body: Any) -> None:
    with pytest.raises(ValidationError):
        model.model_validate(body)


def test_the_link_request_carries_the_new_assertion_and_one_proof() -> None:
    body = {"provider": "yandex_id", "platform": "android", "assertion": "a", "nonce": "n" * 24}
    parsed = LinkIdentityRequest.model_validate({**body, "password": "pw"})
    assert parsed.provider == "yandex_id"
    assert parsed.password == "pw"
    with pytest.raises(ValidationError):
        LinkIdentityRequest.model_validate(body)  # no proof
    with pytest.raises(ValidationError):
        LinkIdentityRequest.model_validate({**body, "password": "pw", "reauth": ASSERTION})
