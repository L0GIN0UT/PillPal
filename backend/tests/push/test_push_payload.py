"""A push payload is ids and enums only; anything else cannot be built (ADR 0008 §2)."""

from __future__ import annotations

import uuid

import pytest
from pydantic import ValidationError

from app.push.base import PUSH_KINDS, PushPayload

ALERT, PROFILE, MEDICATION, GRANT = (uuid.uuid4() for _ in range(4))


def test_missed_payload_wire_form_has_only_known_short_keys() -> None:
    payload = PushPayload(t="missed", a=ALERT, p=PROFILE, m=MEDICATION, s="u")
    assert payload.to_wire() == {
        "v": 1,
        "t": "missed",
        "a": str(ALERT),
        "p": str(PROFILE),
        "m": str(MEDICATION),
        "s": "u",
    }


def test_absent_fields_are_not_on_the_wire() -> None:
    wire = PushPayload(t="link_accepted", p=PROFILE, g=GRANT).to_wire()
    assert wire == {"v": 1, "t": "link_accepted", "p": str(PROFILE), "g": str(GRANT)}


@pytest.mark.parametrize("extra", ["name", "dose", "note", "occurrence_key", "time", "title"])
def test_unknown_keys_are_rejected(extra: str) -> None:
    with pytest.raises(ValidationError):
        PushPayload.model_validate({"t": "missed", "a": str(ALERT), "p": str(PROFILE), extra: "x"})


def test_values_must_be_ids_or_enums_not_text() -> None:
    with pytest.raises(ValidationError):
        PushPayload.model_validate({"t": "missed", "a": "Aspirin 100 mg", "p": str(PROFILE)})
    with pytest.raises(ValidationError):
        PushPayload.model_validate({"t": "taken", "a": str(ALERT), "p": str(PROFILE)})
    with pytest.raises(ValidationError):
        PushPayload.model_validate({"t": "missed", "a": str(ALERT), "p": str(PROFILE), "s": "x"})
    with pytest.raises(ValidationError):
        PushPayload.model_validate({"v": 2, "t": "missed", "a": str(ALERT), "p": str(PROFILE)})


@pytest.mark.parametrize(
    "fields",
    [
        {"t": "missed", "p": PROFILE},  # no alert id
        {"t": "resolved", "a": ALERT},  # no profile
        {"t": "link_accepted", "p": PROFILE},  # no grant
        {"t": "link_restored", "g": GRANT},  # no profile
        {"t": "link_accepted", "p": PROFILE, "g": GRANT, "s": "u"},  # unconfirmed is for alerts
        {"t": "link_restored", "p": PROFILE, "g": GRANT, "a": ALERT},
    ],
)
def test_each_kind_requires_its_ids_and_no_foreign_ones(fields: dict[str, object]) -> None:
    with pytest.raises(ValidationError):
        PushPayload.model_validate(fields)


def test_kinds_match_the_database_check() -> None:
    assert set(PUSH_KINDS) == {"missed", "resolved", "link_accepted", "link_restored"}


def test_payload_is_immutable() -> None:
    payload = PushPayload(t="resolved", a=ALERT, p=PROFILE)
    with pytest.raises(ValidationError):
        payload.t = "missed"  # type: ignore[misc]


def test_a_provider_error_code_with_a_trailing_newline_is_not_kept() -> None:
    from app.push.base import safe_code

    assert safe_code("UNREGISTERED") == "UNREGISTERED"
    assert safe_code("UNREGISTERED\n") == "unknown"
