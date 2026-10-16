"""Write rules by role (ADR 0006 §6): pure, no fixtures."""

from __future__ import annotations

from typing import Any

import pytest

from app.domain.write_access import check_write

SCHEDULE: dict[str, Any] = {"entity": "schedule", "exists": True}


def check(role: Any, entity: str, op: str = "upsert", **kw: Any) -> str:
    kw.setdefault("exists", True)
    kw.setdefault("medication_privacy", None if entity == "profile" else "shared")
    return check_write(role, entity, op, **kw)  # type: ignore[arg-type]


def test_a_caller_without_a_role_sees_nothing() -> None:
    for entity in ("profile", "medication", "schedule", "dose_event"):
        assert check(None, entity) == "not_found"
        assert check(None, entity, "delete") == "not_found"


@pytest.mark.parametrize("privacy", ["shared", "anonymous", "hidden"])
@pytest.mark.parametrize("entity", ["medication", "schedule", "dose_event"])
@pytest.mark.parametrize("op", ["upsert", "delete"])
def test_owner_and_guardian_may_write_everything_on_a_medication(
    privacy: str, entity: str, op: str
) -> None:
    for role in ("owner", "guardian"):
        assert (
            check(role, entity, op, medication_privacy=privacy, incoming_privacy="hidden")
            == "allowed"
        )


def test_profile_delete_belongs_to_the_owner_of_a_managed_profile() -> None:
    assert check("owner", "profile", "delete", profile_kind="managed") == "allowed"
    assert (
        check("owner", "profile", "delete", profile_kind="self") == "allowed"
    )  # the service refuses
    assert check("guardian", "profile", "delete", profile_kind="managed") == "forbidden"
    assert check("guardian", "profile", "upsert", profile_kind="managed") == "allowed"


@pytest.mark.parametrize("role", ["editor", "viewer"])
@pytest.mark.parametrize("privacy", ["anonymous", "hidden", "something-new"])
@pytest.mark.parametrize("entity", ["medication", "schedule", "dose_event"])
def test_rule_1_what_a_projected_role_cannot_fully_see_does_not_exist(
    role: str, privacy: str, entity: str
) -> None:
    for op in ("upsert", "delete"):
        assert check(role, entity, op, medication_privacy=privacy) == "not_found"


@pytest.mark.parametrize("entity", ["medication", "schedule", "dose_event"])
def test_an_unknown_privacy_fails_closed(entity: str) -> None:
    assert check("editor", entity, medication_privacy=None) == "not_found"


def test_rule_2_the_profile_is_read_only_for_editors_and_forbidden_for_viewers() -> None:
    for op in ("upsert", "delete"):
        assert check("editor", "profile", op) == "read_only"
        assert check("viewer", "profile", op) == "forbidden"


def test_rule_3_dose_events_are_forbidden_to_editors() -> None:
    assert check("editor", "dose_event") == "forbidden"


@pytest.mark.parametrize("entity", ["medication", "schedule"])
def test_rule_4_editors_cannot_delete(entity: str) -> None:
    assert check("editor", entity, "delete") == "forbidden"


def test_rule_5_privacy_is_immutable_and_new_medications_are_shared() -> None:
    assert check("editor", "medication", incoming_privacy="shared") == "allowed"
    assert check("editor", "medication", incoming_privacy="hidden") == "forbidden_field"
    assert check("editor", "medication", incoming_privacy="anonymous") == "forbidden_field"
    fresh = {"exists": False, "medication_privacy": None}
    assert check("editor", "medication", incoming_privacy="shared", **fresh) == "allowed"
    assert check("editor", "medication", incoming_privacy="anonymous", **fresh) == "forbidden_field"


def test_rule_6_editors_edit_schedules_of_shared_medications() -> None:
    assert check("editor", "schedule") == "allowed"
    assert check("editor", "schedule", exists=False) == "allowed"


@pytest.mark.parametrize("entity", ["medication", "schedule", "dose_event"])
def test_viewers_are_forbidden_to_write_anything_they_can_see(entity: str) -> None:
    for op in ("upsert", "delete"):
        assert check("viewer", entity, op, incoming_privacy="shared") == "forbidden"
