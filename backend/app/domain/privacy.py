"""Privacy projection of entities for relatives (ADR 0006 §3, TZ §2.1).

Pure functions over JSON-shaped dicts (the ``data`` of an entity state): no IO,
no FastAPI, no ORM. The projection is applied to every relative-facing output
(pull changes, ``current`` of push results, the relative's PDF data).

Every field of every output model is *classified* in a table below, and the
projection is driven by those tables. A test asserts that each table covers
exactly the fields of its output model, so a new field cannot reach a relative
without somebody deciding what it is. Fields missing from a table (a value that
is not part of the model) are dropped for projected roles: fail closed.

Roles: ``owner`` and ``guardian`` have full access, including ``hidden``
medications; ``editor`` and ``viewer`` get the projection.

* ``shared``    - the full entity (dose events without ``note`` and ``device_id``);
* ``anonymous`` - time and status only: a redacted medication, and a schedule
  that keeps the course dates and the times (the client needs them to expand
  occurrences) but no doses;
* ``hidden``    - not returned at all.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any, Literal

Role = Literal["owner", "guardian", "editor", "viewer"]
Form = Literal["full", "projected", "redacted"]

FULL_ACCESS_ROLES: frozenset[str] = frozenset({"owner", "guardian"})


class Treatment(StrEnum):
    """What the projection does with one output field."""

    KEEP = "keep"  # visible in every visible form
    FULL_ONLY = "full_only"  # dropped from the redacted (anonymous) form
    NEVER_PROJECTED = "never_projected"  # dropped for every projected role
    RULE = "rule"  # schedule rule: an allowlist of keys in the redacted form
    ENTITY = "entity"  # envelope payload: projected by the entity's own function
    NULLED = "nulled"  # envelope value: replaced by null for projected roles
    ROUNDED = "rounded"  # coarsened, and shown only where :func:`visible_last_seen` says so


K, F, N = Treatment.KEEP, Treatment.FULL_ONLY, Treatment.NEVER_PROJECTED

# Redacted medication: {id, profile_id, privacy, tz_mode, fixed_tz, redacted: true}.
MEDICATION_FIELDS: dict[str, Treatment] = {
    "id": K,
    "profile_id": K,
    "privacy": K,
    "tz_mode": K,
    "fixed_tz": K,
    "name": F,
    "form": F,
    "strength_text": F,
    "notes": F,
    "stock_count": F,
    "stock_unit": F,
    "low_stock_days": F,
    "stock_set_at": F,
    "version": F,
    "created_at": F,
    "updated_at": F,
}

SCHEDULE_FIELDS: dict[str, Treatment] = {
    "id": K,
    "medication_id": K,
    "rule": Treatment.RULE,
    "version": F,
    "created_at": F,
    "updated_at": F,
}

# Course dates and kind are exposed because the client must expand occurrences;
# the invite disclosure says so. Doses are not.
REDACTED_RULE_KEYS = ("v", "kind", "start_date", "end_date", "weekdays", "interval_days")

# A mark states who took the medicine and when; the note and the writing device
# are personal to the people who record it.
DOSE_EVENT_FIELDS: dict[str, Treatment] = {
    "id": K,
    "profile_id": K,
    "medication_id": K,
    "occurrence_key": K,
    "type": K,
    "target_event_id": K,
    "at": K,
    "recorded_at": K,
    "snooze_until": K,
    "note": N,
    "device_id": N,
}

PROFILE_FIELDS: dict[str, Treatment] = {
    "id": K,
    "kind": K,
    "display_name": K,
    "timezone": K,
    "version": N,
    "created_at": N,
    "updated_at": N,
    "missed_alert_minutes": N,
    "missed_alerts_enabled": N,
}

# The sync ``Change`` envelope (``EntityState`` + ``seq``, ``entity``, ``id``).
ENVELOPE_FIELDS: dict[str, Treatment] = {
    "seq": K,
    "scope": K,
    "entity": K,
    "id": K,
    "op": K,
    "data": Treatment.ENTITY,
    "client_updated_at": K,
    "deleted_at": K,
    "updated_by_device": Treatment.NULLED,
}


# ``ScopeOut`` (one line per accessible profile in a pull response). Role, kind and
# the archive flags describe the caller's own access. ``owner_last_seen_at`` is
# personal data about the *owner* (decision D5): relatives get it floored to the
# hour and only for a self profile that is not their own.
SCOPE_FIELDS: dict[str, Treatment] = {
    "profile_id": K,
    "role": K,
    "kind": K,
    "archived": K,
    "archive_purge_after": K,
    "owner_last_seen_at": Treatment.ROUNDED,
    "cursor": K,
    "backfill_until": K,
}


def floor_to_hour(value: datetime) -> datetime:
    return value.astimezone(UTC).replace(minute=0, second=0, microsecond=0)


def visible_last_seen(role: Role, kind: str, last_seen: datetime | None) -> datetime | None:
    """The owner's last sync time as a relative may see it (hour precision, self scopes only)."""
    if role == "owner" or kind != "self" or last_seen is None:
        return None
    return floor_to_hour(last_seen)


def is_full_access(role: Role) -> bool:
    return role in FULL_ACCESS_ROLES


def form_for(role: Role, privacy: str) -> Form | None:
    """The form of a medication (and of its schedules and events) a role may see.

    ``None`` means the entity is not visible at all.
    """
    if is_full_access(role):
        return "full"
    if privacy == "shared":
        return "projected"
    if privacy == "anonymous":
        return "redacted"
    return None  # hidden, and any level this code does not know


def _select(
    data: Mapping[str, Any], table: Mapping[str, Treatment], drop: set[Treatment]
) -> dict[str, Any]:
    """Copy of ``data`` without fields classified in ``drop`` and without unclassified ones."""
    return {k: v for k, v in data.items() if k in table and table[k] not in drop}


def project_medication(data: Mapping[str, Any], role: Role) -> dict[str, Any] | None:
    form = form_for(role, str(data.get("privacy")))
    if form is None:
        return None
    if form == "full":
        return dict(data)
    if form == "projected":
        return _select(data, MEDICATION_FIELDS, {N})
    return {**_select(data, MEDICATION_FIELDS, {F, N}), "redacted": True}


def _redacted_rule(rule: Mapping[str, Any]) -> dict[str, Any]:
    out = {key: rule[key] for key in REDACTED_RULE_KEYS if key in rule}
    if "times" in rule:
        out["times"] = [{"time": slot["time"]} for slot in rule["times"]]
    return out


def project_schedule(
    data: Mapping[str, Any], medication_privacy: str, role: Role
) -> dict[str, Any] | None:
    form = form_for(role, medication_privacy)
    if form is None:
        return None
    if form == "full":
        return dict(data)
    if form == "projected":
        return _select(data, SCHEDULE_FIELDS, {N})
    out = _select(data, SCHEDULE_FIELDS, {F, N, Treatment.RULE})
    if "rule" in data:
        out["rule"] = _redacted_rule(data["rule"])
    return {**out, "redacted": True}


def project_dose_event(
    data: Mapping[str, Any], medication_privacy: str, role: Role
) -> dict[str, Any] | None:
    form = form_for(role, medication_privacy)
    if form is None:
        return None
    if form == "full":
        return dict(data)
    return _select(data, DOSE_EVENT_FIELDS, {N})


def project_profile(data: Mapping[str, Any], role: Role) -> dict[str, Any]:
    if is_full_access(role):
        return dict(data)
    return _select(data, PROFILE_FIELDS, {N})


def project_envelope(envelope: Mapping[str, Any], role: Role) -> dict[str, Any]:
    """The envelope of a change (everything except ``data``), built from its classification.

    Full-access roles get a copy. For projected roles unclassified keys are dropped and
    ``updated_by_device`` becomes null. ``data`` is rejected: it must go through
    :func:`project_change`, which projects it with the entity's own function.
    """
    if "data" in envelope:
        raise ValueError("project the payload with project_change, not project_envelope")
    if is_full_access(role):
        return dict(envelope)
    out: dict[str, Any] = {}
    for key, value in envelope.items():
        treatment = ENVELOPE_FIELDS.get(key)
        if treatment is Treatment.KEEP:
            out[key] = value
        elif treatment is Treatment.NULLED:
            out[key] = None
    return out


def project_change(
    change: Mapping[str, Any], role: Role, medication_privacy: str | None
) -> dict[str, Any] | None:
    """A whole ``Change`` (envelope and ``data``) for ``role``; ``None`` when not visible.

    ``medication_privacy`` is the privacy of the medication a schedule or dose event
    belongs to (required for those entities, ignored for profiles and medications).
    Tombstones (``data`` is ``None``) keep their envelope: they carry no content.
    """
    if is_full_access(role):
        return dict(change)
    data = change.get("data")
    entity = change.get("entity")
    projected: dict[str, Any] | None = None
    if data is not None:
        if entity in ("schedule", "dose_event") and medication_privacy is None:
            raise ValueError("medication_privacy is required to project a schedule or dose event")
        projectors: dict[str, Callable[[Mapping[str, Any]], dict[str, Any] | None]] = {
            "profile": lambda d: project_profile(d, role),
            "medication": lambda d: project_medication(d, role),
            "schedule": lambda d: project_schedule(d, str(medication_privacy), role),
            "dose_event": lambda d: project_dose_event(d, str(medication_privacy), role),
        }
        projector = projectors.get(str(entity))
        projected = projector(data) if projector is not None else None
        if projected is None:
            return None
    envelope = {k: v for k, v in change.items() if k != "data"}
    return {**project_envelope(envelope, role), "data": projected}
