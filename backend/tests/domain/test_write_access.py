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
        assert check(None, entity, "delete") == "noop"


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


def test_profile_delete_belongs_to_the_owner() -> None:
    assert check("owner", "profile", "delete") == "allowed"  # the service refuses a self profile
    assert check("guardian", "profile", "upsert") == "allowed"


def test_a_guardian_never_deletes_a_profile() -> None:
    # Only a managed profile can have a guardian (a DB trigger), but the rule must not hinge
    # on the profile's kind: defense in depth.
    assert check("guardian", "profile", "delete") == "forbidden"


@pytest.mark.parametrize("role", ["editor", "viewer"])
@pytest.mark.parametrize("privacy", ["anonymous", "hidden", "something-new"])
@pytest.mark.parametrize("entity", ["medication", "schedule", "dose_event"])
def test_rule_1_what_a_projected_role_cannot_fully_see_does_not_exist(
    role: str, privacy: str, entity: str
) -> None:
    assert check(role, entity, "upsert", medication_privacy=privacy) == "not_found"
    # A delete of what the caller cannot see is a silent no-op, like a delete of a missing id.
    assert check(role, entity, "delete", medication_privacy=privacy) == "noop"


@pytest.mark.parametrize("entity", ["medication", "schedule", "dose_event"])
def test_an_unknown_privacy_fails_closed(entity: str) -> None:
    assert check("editor", entity, medication_privacy=None) == "not_found"
    assert check("editor", entity, "delete", medication_privacy=None) == "noop"


@pytest.mark.parametrize("role", ["owner", "guardian", "editor", "viewer"])
@pytest.mark.parametrize("entity", ["medication", "schedule", "dose_event"])
def test_deleting_what_does_not_exist_is_a_noop_for_every_role(role: str, entity: str) -> None:
    assert check(role, entity, "delete", exists=False) == "noop"


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


@pytest.mark.parametrize("role", ["owner", "guardian"])
@pytest.mark.parametrize("entity", ["profile", "medication", "schedule", "dose_event"])
@pytest.mark.parametrize("op", ["upsert", "delete"])
def test_an_archive_is_read_only_for_owner_and_guardian(role: str, entity: str, op: str) -> None:
    assert check(role, entity, op, archived=True) == "read_only"


@pytest.mark.parametrize("entity", ["profile", "medication", "schedule", "dose_event"])
def test_deleting_what_does_not_exist_stays_a_quiet_success_on_an_archive(entity: str) -> None:
    assert check("guardian", entity, "delete", exists=False, archived=True) == "noop"


def test_an_archive_does_not_hide_itself_from_strangers() -> None:
    assert check(None, "medication", archived=True) == "not_found"
