"""Initial schema: users, auth, profiles, medications, schedules, dose events, sync log.

Revision ID: 0001_initial
Revises:
Create Date: 2026-10-16
"""

from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = "0001_initial"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

NOW = sa.text("now()")
TS = sa.DateTime(timezone=True)


def _timestamps() -> list[sa.Column[object]]:
    return [
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("updated_at", TS, server_default=NOW, nullable=False),
    ]


def _sync_columns() -> list[sa.Column[object]]:
    return [
        sa.Column("version", sa.Integer(), server_default=sa.text("1"), nullable=False),
        sa.Column("client_updated_at", TS, nullable=False),
        sa.Column("updated_by_device", sa.Text(), server_default=sa.text("''"), nullable=False),
        sa.Column("deleted_at", TS, nullable=True),
        *_timestamps(),
    ]


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("email", sa.Text(), nullable=False),
        sa.Column("password_hash", sa.Text(), nullable=False),
        sa.Column("region", sa.Text(), nullable=False),
        sa.Column("locale", sa.Text(), server_default=sa.text("'en'"), nullable=False),
        sa.Column("email_verified_at", TS, nullable=True),
        sa.Column("deleted_at", TS, nullable=True),
        *_timestamps(),
        sa.PrimaryKeyConstraint("id", name="pk_users"),
        sa.CheckConstraint("region IN ('ru', 'eu')", name="ck_users_region"),
        sa.CheckConstraint("locale IN ('ru', 'en')", name="ck_users_locale"),
        sa.CheckConstraint("char_length(email) BETWEEN 3 AND 320", name="ck_users_email_length"),
    )
    op.create_index(
        "uq_users_email_active",
        "users",
        [sa.text("lower(email)")],
        unique=True,
        postgresql_where=sa.text("deleted_at IS NULL"),
    )

    op.create_table(
        "devices",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("device_id", sa.Text(), nullable=False),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("last_seen_at", TS, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("id", name="pk_devices"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_devices_user_id_users", ondelete="CASCADE"
        ),
        sa.UniqueConstraint("user_id", "device_id", name="uq_devices_user_id_device_id"),
        sa.CheckConstraint(
            "char_length(device_id) BETWEEN 1 AND 128", name="ck_devices_device_id_length"
        ),
    )

    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("family_id", sa.Uuid(), nullable=False),
        sa.Column("token_hash", sa.Text(), nullable=False),
        sa.Column("device_id", sa.Text(), nullable=True),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("used_at", TS, nullable=True),
        sa.Column("revoked_at", TS, nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_refresh_tokens"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_refresh_tokens_user_id_users", ondelete="CASCADE"
        ),
        sa.UniqueConstraint("token_hash", name="uq_refresh_tokens_token_hash"),
    )
    op.create_index("ix_refresh_tokens_user_id", "refresh_tokens", ["user_id"])
    op.create_index("ix_refresh_tokens_family_id", "refresh_tokens", ["family_id"])

    op.create_table(
        "email_codes",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("purpose", sa.Text(), nullable=False),
        sa.Column("code_hash", sa.Text(), nullable=False),
        sa.Column("attempts", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.Column("expires_at", TS, nullable=False),
        sa.Column("consumed_at", TS, nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_email_codes"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_email_codes_user_id_users", ondelete="CASCADE"
        ),
        sa.CheckConstraint(
            "purpose IN ('verify_email', 'password_reset')", name="ck_email_codes_purpose"
        ),
        sa.CheckConstraint("attempts >= 0", name="ck_email_codes_attempts_non_negative"),
    )
    op.create_index("ix_email_codes_user_id_purpose", "email_codes", ["user_id", "purpose"])

    op.create_table(
        "profiles",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("display_name", sa.Text(), nullable=False),
        sa.Column("timezone", sa.Text(), nullable=False),
        *_sync_columns(),
        sa.PrimaryKeyConstraint("id", name="pk_profiles"),
        sa.ForeignKeyConstraint(
            ["owner_user_id"],
            ["users.id"],
            name="fk_profiles_owner_user_id_users",
            ondelete="CASCADE",
        ),
        sa.CheckConstraint("kind IN ('self', 'managed')", name="ck_profiles_kind"),
        sa.CheckConstraint(
            "char_length(display_name) BETWEEN 1 AND 100", name="ck_profiles_display_name"
        ),
        sa.CheckConstraint("char_length(timezone) BETWEEN 1 AND 64", name="ck_profiles_timezone"),
        sa.CheckConstraint("version >= 1", name="ck_profiles_version_positive"),
    )
    op.create_index("ix_profiles_owner_user_id", "profiles", ["owner_user_id"])
    op.create_index(
        "uq_profiles_one_self_per_user",
        "profiles",
        ["owner_user_id"],
        unique=True,
        postgresql_where=sa.text("kind = 'self'"),
    )

    op.create_table(
        "medications",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("form", sa.Text(), nullable=True),
        sa.Column("strength_text", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("tz_mode", sa.Text(), server_default=sa.text("'local'"), nullable=False),
        sa.Column("fixed_tz", sa.Text(), nullable=True),
        sa.Column("stock_count", sa.Numeric(12, 3), nullable=True),
        sa.Column("stock_unit", sa.Text(), nullable=True),
        sa.Column("low_stock_days", sa.Integer(), nullable=True),
        sa.Column("privacy", sa.Text(), server_default=sa.text("'shared'"), nullable=False),
        *_sync_columns(),
        sa.PrimaryKeyConstraint("id", name="pk_medications"),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_medications_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.CheckConstraint("char_length(name) BETWEEN 1 AND 200", name="ck_medications_name"),
        sa.CheckConstraint("tz_mode IN ('local', 'fixed')", name="ck_medications_tz_mode"),
        sa.CheckConstraint(
            "(tz_mode = 'fixed') = (fixed_tz IS NOT NULL)", name="ck_medications_fixed_tz"
        ),
        sa.CheckConstraint(
            "privacy IN ('shared', 'anonymous', 'hidden')", name="ck_medications_privacy"
        ),
        sa.CheckConstraint(
            "stock_count IS NULL OR stock_count >= 0", name="ck_medications_stock_count"
        ),
        sa.CheckConstraint(
            "low_stock_days IS NULL OR low_stock_days BETWEEN 0 AND 365",
            name="ck_medications_low_stock_days",
        ),
        sa.CheckConstraint("version >= 1", name="ck_medications_version_positive"),
    )
    op.create_index("ix_medications_profile_id", "medications", ["profile_id"])

    op.create_table(
        "schedules",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("medication_id", sa.Uuid(), nullable=False),
        sa.Column("rule", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        *_sync_columns(),
        sa.PrimaryKeyConstraint("id", name="pk_schedules"),
        sa.ForeignKeyConstraint(
            ["medication_id"],
            ["medications.id"],
            name="fk_schedules_medication_id_medications",
            ondelete="CASCADE",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(rule) = 'object' AND rule ? 'v' AND rule ? 'kind'",
            name="ck_schedules_rule_shape",
        ),
        sa.CheckConstraint("version >= 1", name="ck_schedules_version_positive"),
    )
    op.create_index("ix_schedules_medication_id", "schedules", ["medication_id"])

    op.create_table(
        "dose_events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("profile_id", sa.Uuid(), nullable=False),
        sa.Column("medication_id", sa.Uuid(), nullable=False),
        sa.Column("occurrence_key", sa.Text(), nullable=True),
        sa.Column("type", sa.Text(), nullable=False),
        sa.Column("target_event_id", sa.Uuid(), nullable=True),
        sa.Column("at", TS, nullable=False),
        sa.Column("recorded_at", TS, server_default=NOW, nullable=False),
        sa.Column("device_id", sa.Text(), nullable=True),
        sa.Column("note", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id", name="pk_dose_events"),
        sa.ForeignKeyConstraint(
            ["profile_id"],
            ["profiles.id"],
            name="fk_dose_events_profile_id_profiles",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["medication_id"],
            ["medications.id"],
            name="fk_dose_events_medication_id_medications",
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["target_event_id"],
            ["dose_events.id"],
            name="fk_dose_events_target_event_id_dose_events",
        ),
        sa.CheckConstraint(
            "type IN ('taken', 'skipped', 'snoozed', 'undo')", name="ck_dose_events_type"
        ),
        sa.CheckConstraint(
            "(type = 'undo') = (target_event_id IS NOT NULL)", name="ck_dose_events_undo_target"
        ),
        sa.CheckConstraint(
            "note IS NULL OR char_length(note) <= 1000", name="ck_dose_events_note_length"
        ),
        sa.CheckConstraint(
            "occurrence_key IS NULL OR char_length(occurrence_key) <= 64",
            name="ck_dose_events_occurrence_key",
        ),
    )
    op.create_index(
        "ix_dose_events_profile_id_occurrence_key", "dose_events", ["profile_id", "occurrence_key"]
    )
    op.create_index("ix_dose_events_medication_id_at", "dose_events", ["medication_id", "at"])
    op.create_index(
        "ix_dose_events_target_event_id",
        "dose_events",
        ["target_event_id"],
        postgresql_where=sa.text("target_event_id IS NOT NULL"),
    )
    # Append-only: history of doses is immutable (TZ §2.4). Corrections are
    # new ``undo`` events. A future GDPR purge job must disable this trigger
    # explicitly inside its own transaction.
    op.execute(
        """
        CREATE FUNCTION dose_events_append_only() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            RAISE EXCEPTION 'dose_events is append-only (% rejected)', TG_OP
                USING ERRCODE = 'restrict_violation';
        END;
        $$
        """
    )
    op.execute(
        """
        CREATE TRIGGER dose_events_append_only
        BEFORE UPDATE OR DELETE ON dose_events
        FOR EACH ROW EXECUTE FUNCTION dose_events_append_only()
        """
    )

    op.create_table(
        "sync_changes",
        sa.Column("seq", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("entity", sa.Text(), nullable=False),
        sa.Column("entity_id", sa.Uuid(), nullable=False),
        sa.Column("op", sa.Text(), nullable=False),
        sa.Column("created_at", TS, server_default=NOW, nullable=False),
        sa.PrimaryKeyConstraint("seq", name="pk_sync_changes"),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name="fk_sync_changes_user_id_users", ondelete="CASCADE"
        ),
        sa.CheckConstraint(
            "entity IN ('profile', 'medication', 'schedule', 'dose_event')",
            name="ck_sync_changes_entity",
        ),
        sa.CheckConstraint("op IN ('upsert', 'delete')", name="ck_sync_changes_op"),
    )
    op.create_index("ix_sync_changes_user_id_seq", "sync_changes", ["user_id", "seq"])


def downgrade() -> None:
    op.drop_table("sync_changes")
    op.execute("DROP TRIGGER IF EXISTS dose_events_append_only ON dose_events")
    op.execute("DROP FUNCTION IF EXISTS dose_events_append_only()")
    op.drop_table("dose_events")
    op.drop_table("schedules")
    op.drop_table("medications")
    op.drop_table("profiles")
    op.drop_table("email_codes")
    op.drop_table("refresh_tokens")
    op.drop_table("devices")
    op.drop_table("users")
