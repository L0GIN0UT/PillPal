"""The account export (Phase 5.1, docs/spec/export.md): policy, archive format and content."""

from __future__ import annotations

import io
import json
import re
import uuid
import zipfile
from datetime import UTC, datetime
from typing import Any

from httpx import AsyncClient

from app.services.export_archive import (
    FORMAT_VERSION,
    ExportData,
    build_archive,
    collect_account_data,
    exported_columns,
)
from app.services.personal_data import TABLE_CLASSIFICATION
from tests.grace_helpers import app_of, delete_and_erase
from tests.helpers import (
    User,
    create_invite,
    create_managed_profile,
    create_medication,
    create_schedule,
    link_accounts,
    register,
    token_of,
)
from tests.push_helpers import put_token
from tests.test_sync import mut, push
from tests.ward_helpers import make_ward

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
SECRET_COLUMN = re.compile(r"^password|_hash$|token|_enc$|digest")
EXPORTED = sorted(name for name, info in TABLE_CLASSIFICATION.items() if info.export == "rows")

# --- policy (no database) ---------------------------------------------------------------------


def test_every_table_has_an_export_decision() -> None:
    for name, info in TABLE_CLASSIFICATION.items():
        if info.export == "rows":
            assert info.export_reason is None, f"{name}: exported tables need no reason"
        else:
            assert info.export_reason, f"{name}: say why it is not exported (export_reason)"
    assert {"users", "profiles", "medications", "schedules", "dose_events"} <= set(EXPORTED)
    assert {"refresh_tokens", "email_codes", "sync_changes", "push_outbox"}.isdisjoint(EXPORTED)


def test_no_exported_column_looks_like_a_secret() -> None:
    for name in EXPORTED:
        for column in exported_columns(name):
            assert not SECRET_COLUMN.search(column), f"{name}.{column} must be excluded"


def test_exclusions_name_real_columns() -> None:
    for name in EXPORTED:
        info = TABLE_CLASSIFICATION[name]
        everything = set(exported_columns(name, with_excluded=True))
        assert set(info.export_exclude) <= everything, name
        assert set(exported_columns(name)) == everything - set(info.export_exclude), name
        assert info.owner_column in everything, name
        assert {column for column, _ in info.export_also} <= everything, name


def test_phase4_medication_fields_are_exported_and_credentials_are_not() -> None:
    assert {
        "gtin",
        "gtin_link_shared",
        "gtin_link_consent_version",
        "gtin_link_consented_at",
        "manual_ingredients",
        "catalog_product_id",
    } <= set(exported_columns("medications"))
    assert "password_hash" not in exported_columns("users")
    assert "token" not in exported_columns("push_tokens")
    assert "token_hash" not in exported_columns("invites")


# --- the archive format (pure) ----------------------------------------------------------------


def sample_data() -> ExportData:
    return ExportData(
        {
            "users": [
                {
                    "id": uuid.UUID(int=1),
                    "email": "synthetic@example.com",
                    "created_at": datetime(2026, 1, 2, 3, 4, 5, tzinfo=UTC),
                }
            ],
            "medications": [{"id": uuid.UUID(int=2), "name": "Аспирин"}],
        }
    )


def read(archive: bytes) -> dict[str, Any]:
    with zipfile.ZipFile(io.BytesIO(archive)) as zf:
        return {name: json.loads(zf.read(name)) for name in zf.namelist()}


def test_archive_layout_and_manifest() -> None:
    members = read(build_archive(sample_data(), region="eu", now=NOW))
    manifest = members["manifest.json"]
    assert manifest["format_version"] == FORMAT_VERSION == 1
    assert manifest["region"] == "eu"
    assert manifest["generated_at"] == "2026-11-10T12:00:00+00:00"
    assert manifest["tables"]["users"] == 1
    assert manifest["tables"]["medications"] == 1
    # Every exported table has a file, also when it has no rows.
    assert set(manifest["tables"]) == set(EXPORTED)
    assert set(members) == {"manifest.json", *(f"tables/{t}.json" for t in EXPORTED)}
    assert members["tables/schedules.json"] == []


def test_values_are_json_friendly_and_unicode_is_kept() -> None:
    raw = build_archive(sample_data(), region="ru", now=NOW)
    members = read(raw)
    assert members["tables/users.json"][0]["id"] == str(uuid.UUID(int=1))
    assert members["tables/users.json"][0]["created_at"] == "2026-01-02T03:04:05+00:00"
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        assert "Аспирин" in zf.read("tables/medications.json").decode("utf-8")


def test_archive_is_deterministic_and_ordered() -> None:
    first = build_archive(sample_data(), region="ru", now=NOW)
    assert first == build_archive(sample_data(), region="ru", now=NOW)
    with zipfile.ZipFile(io.BytesIO(first)) as zf:
        names = zf.namelist()
    assert names[0] == "manifest.json"
    assert names[1:] == sorted(names[1:])


# --- content (real PostgreSQL) ----------------------------------------------------------------


async def archive_of(client: AsyncClient, user: User) -> tuple[bytes, dict[str, Any]]:
    async with app_of(client).state.sessionmaker() as session:
        data = await collect_account_data(session, uuid.UUID(user.id))
    raw = build_archive(data, region="ru", now=NOW)
    return raw, read(raw)


def text_of(members: dict[str, Any]) -> str:
    return json.dumps(members, ensure_ascii=False)


async def send_dose(client: AsyncClient, user: User, medication_id: str, note: str) -> None:
    await push(
        client,
        user,
        user.id[:8],
        [
            mut(
                "dose_event",
                "upsert",
                str(uuid.uuid4()),
                {
                    "medication_id": medication_id,
                    "type": "taken",
                    "at": "2026-10-01T08:00:00+00:00",
                    "note": note,
                },
            )
        ],
    )


async def test_the_archive_holds_every_table_of_the_account_and_nothing_of_others(
    client: AsyncClient,
) -> None:
    me, relative, other, ward_owner = [await register(client) for _ in range(4)]
    # My own medications, including the ones hidden from relatives.
    mine = [
        await create_medication(
            client,
            me,
            name=f"Needle-Med-{kind}-Таблетка",
            notes=f"needle-note-{kind}",
            strength_text=f"needle-strength-{kind}",
            privacy=kind,
        )
        for kind in ("shared", "anonymous", "hidden")
    ]
    await create_schedule(client, me, mine[0]["id"])
    await send_dose(client, me, mine[0]["id"], "needle-dose-note")
    ward = await create_managed_profile(client, me, name="Needle-Ward-Name")
    await create_medication(client, me, profile_id=ward, name="Needle-Ward-Med")
    await put_token(client, me, "needle-device", token="needle-push-token-secret")
    # Relations in both directions plus an open invite.
    await link_accounts(client, me, relative, "viewer", ward)  # a grant on my profile
    await link_accounts(client, other, me, "editor")  # I hold a grant on another's profile
    invite = await create_invite(client, me)
    # Other accounts' data that must never leak, among them a profile I only co-guard.
    foreign = await create_medication(client, other, name="Foreign-Med", notes="foreign-note")
    await send_dose(client, other, foreign["id"], "foreign-dose-note")
    guarded = await create_managed_profile(client, ward_owner, name="Foreign-Ward-Name")
    await create_medication(client, ward_owner, profile_id=guarded, name="Foreign-Guarded-Med")
    await link_accounts(client, ward_owner, me, "guardian", guarded)

    _, members = await archive_of(client, me)
    text = text_of(members)

    for needle in (
        me.email,
        "Needle-Med-hidden-Таблетка",
        "Needle-Med-anonymous-Таблетка",
        "needle-note-hidden",
        "needle-strength-anonymous",
        "needle-dose-note",
        "Needle-Ward-Name",
        "Needle-Ward-Med",
        "needle-device",
    ):
        assert needle in text, needle
    for secret in (
        "Foreign-",
        "foreign-",
        other.email,
        relative.email,
        ward_owner.email,
        "needle-push-token-secret",
        token_of(invite),
        "argon2",
        me.password,
        me.refresh_token,
        me.access_token,
    ):
        assert secret not in text, secret
    # Every exported table is represented in this scenario (one that stays empty would be
    # untested), and the manifest counts match the files.
    for name in EXPORTED:
        assert members["manifest.json"]["tables"][name] == len(members[f"tables/{name}.json"])
        assert members["manifest.json"]["tables"][name] > 0, name
    assert [row["id"] for row in members["tables/users.json"]] == [me.id]


async def test_the_export_is_repeatable(client: AsyncClient) -> None:
    me = await register(client)
    await create_medication(client, me)
    first, _ = await archive_of(client, me)
    second, _ = await archive_of(client, me)
    assert first == second


async def test_an_inherited_profile_is_exported_for_the_heir_only(client: AsyncClient) -> None:
    ward = await make_ward(client)
    before = text_of((await archive_of(client, ward.first))[1])
    assert "Ward Tablet" not in before  # a co-guardian does not own it yet
    await delete_and_erase(client, ward.owner)

    heir = text_of((await archive_of(client, ward.first))[1])
    assert '"owner_user_id": "' + ward.first.id in heir
    assert "Synthetic Ward" in heir
    assert "Ward Tablet" in heir
    assert "ward note" in heir
    bystander = text_of((await archive_of(client, ward.second))[1])
    assert "Synthetic Ward" not in bystander
    assert "Ward Tablet" not in bystander
