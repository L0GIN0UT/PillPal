"""Privacy projection (ADR 0006 §3): pure functions, no fixtures, no services.

The classification tests are the guard rail: adding a field to an output model
without classifying it here (and in ``app.domain.privacy``) fails the suite.
"""

from __future__ import annotations

import copy
import json
from typing import Any

import pytest

from app.domain import privacy
from app.domain.privacy import Role, Treatment
from app.schemas.entities import (
    Change,
    DoseEventOut,
    MedicationOut,
    ProfileOut,
    ScheduleOut,
)

FULL_ACCESS: list[Role] = ["owner", "guardian"]
PROJECTED: list[Role] = ["editor", "viewer"]
ALL_ROLES: list[Role] = [*FULL_ACCESS, *PROJECTED]


def sample(table: dict[str, Treatment], **overrides: Any) -> dict[str, Any]:
    """One value per classified field; each value is a unique sentinel."""
    data: dict[str, Any] = {name: f"SENTINEL-{name}" for name in table}
    data.update(overrides)
    return data


def leaked(result: dict[str, Any] | None, sentinels: set[str]) -> set[str]:
    blob = json.dumps(result)
    return {s for s in sentinels if s in blob}


# --- classification covers every output field ------------------------------------------


@pytest.mark.parametrize(
    ("model", "table"),
    [
        (MedicationOut, privacy.MEDICATION_FIELDS),
        (ScheduleOut, privacy.SCHEDULE_FIELDS),
        (DoseEventOut, privacy.DOSE_EVENT_FIELDS),
        (ProfileOut, privacy.PROFILE_FIELDS),
        (Change, privacy.ENVELOPE_FIELDS),
    ],
)
def test_every_output_field_is_classified(model: Any, table: dict[str, Treatment]) -> None:
    assert set(model.model_fields) == set(table)


def test_the_envelope_marks_exactly_the_device_field_and_the_payload() -> None:
    by_treatment: dict[Treatment, set[str]] = {}
    for name, treatment in privacy.ENVELOPE_FIELDS.items():
        by_treatment.setdefault(treatment, set()).add(name)
    assert by_treatment[Treatment.NULLED] == {"updated_by_device"}
    assert by_treatment[Treatment.ENTITY] == {"data"}


def test_free_text_and_stock_fields_are_not_visible_in_the_redacted_form() -> None:
    kept = {n for n, t in privacy.MEDICATION_FIELDS.items() if t is Treatment.KEEP}
    assert kept == {"id", "profile_id", "privacy", "tz_mode", "fixed_tz"}


# --- who sees which form ---------------------------------------------------------------


@pytest.mark.parametrize("role", FULL_ACCESS)
@pytest.mark.parametrize("level", ["shared", "anonymous", "hidden"])
def test_full_access_roles_see_everything(role: Role, level: str) -> None:
    assert privacy.form_for(role, level) == "full"
    assert privacy.is_full_access(role)


@pytest.mark.parametrize("role", PROJECTED)
def test_projected_roles_see_shared_redacted_anonymous_and_no_hidden(role: Role) -> None:
    assert not privacy.is_full_access(role)
    assert privacy.form_for(role, "shared") == "projected"
    assert privacy.form_for(role, "anonymous") == "redacted"
    assert privacy.form_for(role, "hidden") is None


def test_unknown_values_fail_closed() -> None:
    assert privacy.form_for("editor", "something-new") is None
    assert privacy.form_for(None, "shared") == "projected"  # type: ignore[arg-type]
    assert not privacy.is_full_access("superuser")  # type: ignore[arg-type]
    assert privacy.form_for("superuser", "hidden") is None  # type: ignore[arg-type]


# --- medication ------------------------------------------------------------------------


@pytest.mark.parametrize("role", FULL_ACCESS)
def test_full_access_medication_is_returned_unchanged_as_a_copy(role: Role) -> None:
    data = sample(privacy.MEDICATION_FIELDS, privacy="hidden")
    result = privacy.project_medication(data, role)
    assert result == data
    assert result is not data


@pytest.mark.parametrize("role", PROJECTED)
def test_shared_medication_is_full_for_projected_roles(role: Role) -> None:
    data = sample(privacy.MEDICATION_FIELDS, privacy="shared")
    assert privacy.project_medication(data, role) == data


@pytest.mark.parametrize("role", PROJECTED)
def test_anonymous_medication_is_redacted(role: Role) -> None:
    data = sample(privacy.MEDICATION_FIELDS, privacy="anonymous", tz_mode="fixed")
    result = privacy.project_medication(data, role)
    assert result == {
        "id": "SENTINEL-id",
        "profile_id": "SENTINEL-profile_id",
        "privacy": "anonymous",
        "tz_mode": "fixed",
        "fixed_tz": "SENTINEL-fixed_tz",
        "redacted": True,
    }


@pytest.mark.parametrize("role", PROJECTED)
def test_hidden_medication_is_not_returned(role: Role) -> None:
    assert (
        privacy.project_medication(sample(privacy.MEDICATION_FIELDS, privacy="hidden"), role)
        is None
    )


def test_projection_never_mutates_its_input() -> None:
    data = sample(privacy.MEDICATION_FIELDS, privacy="anonymous")
    before = copy.deepcopy(data)
    privacy.project_medication(data, "viewer")
    assert data == before


def test_unclassified_extra_fields_are_dropped_for_projected_roles_only() -> None:
    med = sample(privacy.MEDICATION_FIELDS, privacy="shared", future_field="x")
    sched = sample(privacy.SCHEDULE_FIELDS, rule=rule(), future_field="x")
    event = sample(privacy.DOSE_EVENT_FIELDS, future_field="x")
    for level in ("shared", "anonymous"):
        for result in (
            privacy.project_medication({**med, "privacy": level}, "viewer"),
            privacy.project_schedule(sched, level, "viewer"),
            privacy.project_dose_event(event, level, "viewer"),
        ):
            assert result is not None
            assert "future_field" not in result
    assert privacy.project_medication(med, "owner") == med
    assert privacy.project_schedule(sched, "shared", "owner") == sched


# --- schedule --------------------------------------------------------------------------

DOSE = {"amount": "1", "unit": "tablet"}


def rule(kind: str = "daily", **extra: Any) -> dict[str, Any]:
    times = (
        []
        if kind == "as_needed"
        else [{"time": "08:00", "dose": DOSE}, {"time": "20:00", "dose": DOSE}]
    )
    return {
        "v": 1,
        "kind": kind,
        "start_date": "2026-10-16",
        "end_date": "2026-12-31",
        "times": times,
        **extra,
    }


def schedule(**rule_args: Any) -> dict[str, Any]:
    return sample(privacy.SCHEDULE_FIELDS, rule=rule(**rule_args))


@pytest.mark.parametrize("role", FULL_ACCESS)
@pytest.mark.parametrize("level", ["shared", "anonymous", "hidden"])
def test_full_access_schedule_is_unchanged(role: Role, level: str) -> None:
    data = schedule()
    assert privacy.project_schedule(data, level, role) == data


@pytest.mark.parametrize("role", PROJECTED)
def test_schedule_of_a_shared_medication_is_full(role: Role) -> None:
    data = schedule(kind="weekdays", weekdays=[1, 3])
    assert privacy.project_schedule(data, "shared", role) == data


@pytest.mark.parametrize("role", PROJECTED)
def test_schedule_of_a_hidden_medication_is_not_returned(role: Role) -> None:
    assert privacy.project_schedule(schedule(), "hidden", role) is None


@pytest.mark.parametrize(
    ("kind", "extra"),
    [
        ("daily", {}),
        ("weekdays", {"weekdays": [1, 5]}),
        ("interval_days", {"interval_days": 3}),
        ("as_needed", {}),
    ],
)
def test_anonymous_schedule_keeps_course_and_times_but_no_doses(
    kind: str, extra: dict[str, Any]
) -> None:
    data = schedule(kind=kind, **extra)
    result = privacy.project_schedule(data, "anonymous", "viewer")
    assert result is not None
    assert set(result) == {"id", "medication_id", "redacted", "rule"}
    assert result["redacted"] is True
    expected_times = [] if kind == "as_needed" else [{"time": "08:00"}, {"time": "20:00"}]
    assert result["rule"] == {
        "v": 1,
        "kind": kind,
        "start_date": "2026-10-16",
        "end_date": "2026-12-31",
        "times": expected_times,
        **extra,
    }
    assert "dose" not in json.dumps(result)
    assert "tablet" not in json.dumps(result)


def test_anonymous_schedule_rule_is_an_allowlist() -> None:
    data = schedule(future_rule_key="secret", end_date=None)
    result = privacy.project_schedule(data, "anonymous", "editor")
    assert result is not None
    assert "future_rule_key" not in result["rule"]
    assert result["rule"]["end_date"] is None


def test_anonymous_schedule_without_a_rule_has_none() -> None:
    data = sample(privacy.SCHEDULE_FIELDS)
    data.pop("rule")
    result = privacy.project_schedule(data, "anonymous", "viewer")
    assert result == {
        "id": "SENTINEL-id",
        "medication_id": "SENTINEL-medication_id",
        "redacted": True,
    }


def test_anonymous_schedule_leaks_no_bookkeeping() -> None:
    result = privacy.project_schedule(schedule(), "anonymous", "viewer")
    sentinels = {f"SENTINEL-{n}" for n in ("version", "created_at", "updated_at")}
    assert leaked(result, sentinels) == set()


# --- dose events -----------------------------------------------------------------------


@pytest.mark.parametrize("role", FULL_ACCESS)
def test_full_access_dose_event_is_unchanged(role: Role) -> None:
    data = sample(privacy.DOSE_EVENT_FIELDS)
    assert privacy.project_dose_event(data, "hidden", role) == data


@pytest.mark.parametrize("role", PROJECTED)
@pytest.mark.parametrize("level", ["shared", "anonymous"])
def test_projected_dose_event_has_no_note_and_no_device(role: Role, level: str) -> None:
    data = sample(privacy.DOSE_EVENT_FIELDS)
    result = privacy.project_dose_event(data, level, role)
    assert result is not None
    assert set(data) - set(result) == {"note", "device_id"}


@pytest.mark.parametrize("role", PROJECTED)
def test_dose_event_of_a_hidden_medication_is_not_returned(role: Role) -> None:
    assert privacy.project_dose_event(sample(privacy.DOSE_EVENT_FIELDS), "hidden", role) is None


# --- profile and envelope --------------------------------------------------------------


@pytest.mark.parametrize("role", FULL_ACCESS)
def test_full_access_profile_is_unchanged(role: Role) -> None:
    data = sample(privacy.PROFILE_FIELDS)
    assert privacy.project_profile(data, role) == data


@pytest.mark.parametrize("role", PROJECTED)
def test_projected_profile_is_name_kind_and_zone_only(role: Role) -> None:
    result = privacy.project_profile(sample(privacy.PROFILE_FIELDS), role)
    assert result is not None
    assert set(result) == {"id", "kind", "display_name", "timezone"}


@pytest.mark.parametrize("role", PROJECTED)
def test_envelope_hides_the_writing_device_from_projected_roles(role: Role) -> None:
    envelope = {
        "seq": 7,
        "updated_by_device": "pixel-7",
        "client_updated_at": "2026-10-16T00:00:00Z",
    }
    assert privacy.project_envelope(envelope, role) == {**envelope, "updated_by_device": None}
    assert envelope["updated_by_device"] == "pixel-7"


@pytest.mark.parametrize("role", PROJECTED)
def test_envelope_is_built_from_the_classification(role: Role) -> None:
    envelope = {"seq": 7, "entity": "medication", "updated_by_device": "pixel-7", "future": "x"}
    result = privacy.project_envelope(envelope, role)
    assert "future" not in result  # unclassified fields fail closed
    assert result["updated_by_device"] is None
    with pytest.raises(ValueError, match="project_change"):
        privacy.project_envelope({**envelope, "data": {"name": "x"}}, role)


@pytest.mark.parametrize("role", FULL_ACCESS)
def test_envelope_is_unchanged_for_full_access_roles(role: Role) -> None:
    envelope = {"seq": 7, "updated_by_device": "pixel-7", "future": "x"}
    assert privacy.project_envelope(envelope, role) == envelope


def change(entity: str, data: dict[str, Any] | None, **extra: Any) -> dict[str, Any]:
    return {
        "seq": 3,
        "entity": entity,
        "id": "e1",
        "op": "upsert" if data is not None else "delete",
        "data": data,
        "client_updated_at": "2026-10-16T00:00:00Z",
        "updated_by_device": "pixel-7",
        "deleted_at": None,
        **extra,
    }


@pytest.mark.parametrize("role", PROJECTED)
def test_project_change_projects_envelope_and_data_together(role: Role) -> None:
    med = sample(privacy.MEDICATION_FIELDS, privacy="anonymous")
    result = privacy.project_change(change("medication", med), role, None)
    assert result is not None
    assert result["updated_by_device"] is None
    assert result["data"]["redacted"] is True
    assert "SENTINEL-name" not in json.dumps(result)


@pytest.mark.parametrize("role", PROJECTED)
def test_project_change_covers_every_entity(role: Role) -> None:
    sched = sample(privacy.SCHEDULE_FIELDS, rule=rule())
    event = sample(privacy.DOSE_EVENT_FIELDS)
    profile = sample(privacy.PROFILE_FIELDS)
    got = privacy.project_change(change("schedule", sched), role, "anonymous")
    assert got is not None
    assert got["data"]["redacted"] is True
    got = privacy.project_change(change("dose_event", event), role, "shared")
    assert got is not None
    assert "note" not in got["data"]
    got = privacy.project_change(change("profile", profile), role, None)
    assert got is not None
    assert set(got["data"]) == {"id", "kind", "display_name", "timezone"}


@pytest.mark.parametrize("role", PROJECTED)
def test_project_change_drops_hidden_children_and_keeps_tombstones(role: Role) -> None:
    hidden = privacy.project_change(change("schedule", schedule()), role, "hidden")
    assert hidden is None
    tombstone = privacy.project_change(
        change("medication", None, updated_by_device="d"), role, None
    )
    assert tombstone is not None
    assert tombstone["data"] is None
    assert tombstone["updated_by_device"] is None


@pytest.mark.parametrize("role", FULL_ACCESS)
def test_project_change_is_the_identity_for_full_access(role: Role) -> None:
    c = change("medication", sample(privacy.MEDICATION_FIELDS, privacy="hidden"))
    assert privacy.project_change(c, role, None) == c


def test_project_change_requires_the_medication_privacy_for_children() -> None:
    with pytest.raises(ValueError, match="medication_privacy"):
        privacy.project_change(change("schedule", schedule()), "viewer", None)
