"""Server-side pause while a profile has no health-data consent (ADR 0016 section 5).

The app stops syncing while ``health_data`` is in ``missing`` of ``GET /v1/me/consents``, so the
server must not keep acting on that data either: no missed-dose detection and no pushes, nothing
served to relatives, nothing counted for the catalog. Owner decisions of 2026-11-11:

* **A. Only a missing consent pauses.** A profile's owner is unconsented when they have no active
  (not withdrawn) ``health_data`` record of *any* version: never recorded or withdrawn. A new text
  version ("outdated") is a client gate only; processing continues under the previous consent.
* **B. Any full-access guardian is enough.** A profile is *not* paused while its owner, or any
  holder of a guardian grant (not pending deletion), has such a record. The guardian test reads
  ``profile_grants`` directly, never ``grant_is_active``, so it does not depend on itself.

``CONSENT_SERVER_PAUSE_ENABLED=false`` turns the pause off. Nothing is stored: every check is a
query-time ``EXISTS`` on ``consents`` (index ``uq_consents_active``), so a re-accepted
consent resumes everything at the next read. The flag is the only setting read, held process-wide
by :func:`configure` (``create_app``, the worker's ``on_startup`` and the job CLI); unconfigured,
the pause is on.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import ColumnElement, Select, SQLColumnExpression, exists, or_, select, true

from app.config import Settings
from app.db.consents import Consent
from app.db.models import Profile, User
from app.db.relatives import ProfileGrant

HEALTH_DATA = "health_data"

_settings: Settings | None = None


def configure(settings: Settings) -> None:
    """Remember the settings whose pause flag the predicates read (kept, not copied)."""
    global _settings
    _settings = settings


def enabled() -> bool:
    return _settings is None or _settings.consent_server_pause_enabled


def _pending_users() -> Select[uuid.UUID]:
    # ``correlate(None)``: never fold into an enclosing query that also reads ``users``.
    return select(User.id).where(User.deletion_requested_at.is_not(None)).correlate(None)


def _active_record(
    user_id: SQLColumnExpression[uuid.UUID], accepted_by: datetime | None
) -> list[ColumnElement[bool]]:
    conditions = [
        Consent.user_id == user_id,
        Consent.kind == HEALTH_DATA,
        Consent.withdrawn_at.is_(None),
    ]
    if accepted_by is not None:
        conditions.append(Consent.accepted_at <= accepted_by)
    return conditions


def profile_consented(accepted_by: datetime | None = None) -> ColumnElement[bool]:
    """Predicate over ``Profile``: its owner or one of its guardians has an active health-data
    record (always true when the pause is off).

    ``accepted_by`` only counts records accepted at or before that instant; the detector passes
    its window start, so the tick in which a consent returns is skipped and no alert is raised
    for doses that fell due while the app was not syncing.
    """
    if not enabled():
        return true()
    owner = exists().where(*_active_record(Profile.owner_user_id, accepted_by))
    guardian = exists().where(
        ProfileGrant.profile_id == Profile.id,
        ProfileGrant.role == "guardian",
        ProfileGrant.grantee_user_id.not_in(_pending_users()),
        *_active_record(ProfileGrant.grantee_user_id, accepted_by),
    )
    return or_(
        owner.correlate_except(Consent),
        guardian.correlate_except(ProfileGrant, Consent),
    )
