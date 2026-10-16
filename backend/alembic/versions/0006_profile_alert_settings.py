"""Profiles: missed-dose alert settings (TZ §2.5, ADR 0007).

``missed_alert_minutes`` (5..720, default 30) is how long after the due time a
dose may stay unmarked before relatives are alerted; ``missed_alerts_enabled``
switches the alerts for the profile off. Both are synced profile fields with
keep-on-absent semantics.

Locking: ``ADD COLUMN ... DEFAULT`` with a constant is a catalog-only change on
PostgreSQL 11+, and the new CHECK holds for every existing row (all are 30),
so ``VALIDATE`` is a short scan of a small table; ``lock_timeout`` makes the
revision fail fast instead of queueing behind a long transaction.

The revision id is shorter than the plan's ``0006_profile_missed_alert_settings``:
``alembic_version.version_num`` is VARCHAR(32).

Revision ID: 0006_profile_alert_settings
Revises: 0005_invites
Create Date: 2026-10-16
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0006_profile_alert_settings"
down_revision: str | None = "0005_invites"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_CHECK = "ck_profiles_missed_alert_minutes"


def upgrade() -> None:
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.add_column(
        "profiles",
        sa.Column(
            "missed_alert_minutes", sa.Integer(), server_default=sa.text("30"), nullable=False
        ),
    )
    op.add_column(
        "profiles",
        sa.Column(
            "missed_alerts_enabled", sa.Boolean(), server_default=sa.text("true"), nullable=False
        ),
    )
    op.execute(
        f"ALTER TABLE profiles ADD CONSTRAINT {_CHECK} "
        "CHECK (missed_alert_minutes BETWEEN 5 AND 720) NOT VALID"
    )
    op.execute(f"ALTER TABLE profiles VALIDATE CONSTRAINT {_CHECK}")


def downgrade() -> None:
    # The chosen thresholds are lost; every profile is back to the server default.
    op.execute("SET LOCAL lock_timeout = '5s'")
    op.execute(f"ALTER TABLE profiles DROP CONSTRAINT {_CHECK}")
    op.drop_column("profiles", "missed_alerts_enabled")
    op.drop_column("profiles", "missed_alert_minutes")
