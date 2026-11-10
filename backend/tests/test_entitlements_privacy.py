"""Entitlements and the admin audit in the personal-data inventory: erasure, export, retention."""

from __future__ import annotations

import uuid
from datetime import timedelta

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.services.export_archive import exported_columns
from app.services.personal_data import TABLE_CLASSIFICATION
from tests.entitlement_helpers import insert_audit, insert_entitlement, rows
from tests.grace_helpers import count, delete_and_erase, in_days, run_retention
from tests.helpers import register
from tests.test_export_archive import archive_of, text_of


def test_the_inventory_classifies_both_tables() -> None:
    entitlements = TABLE_CLASSIFICATION["entitlements"]
    audit = TABLE_CLASSIFICATION["admin_audit"]
    assert (entitlements.kind, entitlements.owner_column) == ("personal", "user_id")
    assert (audit.kind, audit.owner_column) == ("personal", "target_user_id")
    assert entitlements.export == audit.export == "rows"
    assert not entitlements.export_exclude
    # The operator's own data is not the subject's: it stays out of the archive.
    assert set(audit.export_exclude) == {"actor", "os_user", "host"}
    assert set(exported_columns("admin_audit")) == {
        "id",
        "at",
        "action",
        "target_user_id",
        "object_id",
        "kind",
    }


async def test_erasing_an_account_deletes_its_entitlements_and_unlinks_its_audit(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    gone, kept = await register(client), await register(client)
    gone_entitlement = await insert_entitlement(engine, gone.id)
    kept_entitlement = await insert_entitlement(engine, kept.id)
    erased_audit = await insert_audit(engine, gone.id, gone_entitlement)
    kept_audit = await insert_audit(engine, kept.id, kept_entitlement)
    unlinked_audit = await insert_audit(engine, None, None)

    await delete_and_erase(client, gone)

    assert await count(engine, "entitlements", "user_id = :u", u=uuid.UUID(gone.id)) == 0
    assert await count(engine, "entitlements", "id = :i", i=kept_entitlement) == 1
    left = {r["id"]: r for r in await rows(engine, "SELECT * FROM admin_audit")}
    assert set(left) == {erased_audit, kept_audit, unlinked_audit}  # the audit stays
    # Without the person: neither the account nor the id that identifies the grant.
    assert left[erased_audit]["target_user_id"] is None
    assert left[erased_audit]["object_id"] is None
    assert left[erased_audit]["action"] == "entitlement_grant"
    assert left[erased_audit]["kind"] == "ads_removed"
    # Another account's row is untouched.
    assert str(left[kept_audit]["target_user_id"]) == kept.id
    assert left[kept_audit]["object_id"] == kept_entitlement


async def test_the_export_holds_the_accounts_entitlements_and_audit_rows_only(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    me, other = await register(client), await register(client)
    mine = await insert_entitlement(engine, me.id, "limits_lifted", "promo")
    revoked = await insert_entitlement(
        engine, me.id, "ads_removed", "purchase", revoked_at=in_days(-1)
    )
    await insert_entitlement(engine, other.id, "ads_removed", "admin_grant")
    about_me = await insert_audit(engine, me.id, mine, actor="needle-operator-handle")
    await insert_audit(engine, other.id, None, actor="foreign-operator-handle")

    _, members = await archive_of(client, me)
    text = text_of(members)

    assert {row["id"] for row in members["tables/entitlements.json"]} == {str(mine), str(revoked)}
    [audit] = members["tables/admin_audit.json"]
    assert audit["id"] == str(about_me)
    assert audit["object_id"] == str(mine)
    assert audit["target_user_id"] == me.id
    assert set(audit) == {"id", "at", "action", "target_user_id", "object_id", "kind"}
    # The operator columns are the operator's data: never in the subject's archive.
    for needle in ("needle-operator-handle", "synthetic-os-user", "synthetic-host"):
        assert needle not in text, needle
    assert "foreign-operator-handle" not in text
    manifest = members["manifest.json"]["tables"]
    assert (manifest["entitlements"], manifest["admin_audit"]) == (2, 1)


async def test_retention_deletes_audit_rows_after_the_configured_days(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    # The test settings use the default of 365 days.
    old = await insert_audit(engine, user.id, None, at=in_days(-366))
    edge = await insert_audit(engine, user.id, None, at=in_days(-364))
    detached = await insert_audit(engine, None, None, at=in_days(-400))
    fresh = await insert_audit(engine, user.id, None)

    report = await run_retention(client, in_days(0) + timedelta(minutes=1))

    assert report.admin_audit_deleted == 2
    left = {r["id"] for r in await rows(engine, "SELECT id FROM admin_audit")}
    assert left == {edge, fresh}
    assert old not in left
    assert detached not in left
    assert (await run_retention(client, in_days(0))).admin_audit_deleted == 0


async def test_retention_leaves_entitlements_alone(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await insert_entitlement(engine, user.id, granted_at=in_days(-900), expires_at=in_days(-800))
    await run_retention(client, in_days(0))
    assert await count(engine, "entitlements") == 1
