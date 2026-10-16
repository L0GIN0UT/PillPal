"""Account deletion erases data, password changes cut old tokens, tombstones hold no content."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import request_deletion, run_erase_job
from tests.helpers import (
    User,
    create_invite,
    create_medication,
    create_schedule,
    daily_rule,
    last_code,
    link_accounts,
    register,
    token_of,
)
from tests.test_sync import med_data, mut, push


async def delete_me(client: AsyncClient, user: User, password: str | None = None) -> Any:
    body = {"password": user.password if password is None else password}
    return await client.request("DELETE", "/v1/me", json=body, headers=user.headers)


# --- 14. DELETE /v1/me needs the password ---------------------------------------------


async def test_delete_me_requires_current_password(client: AsyncClient) -> None:
    user = await register(client)
    no_body = await client.request("DELETE", "/v1/me", headers=user.headers)
    assert no_body.status_code == 422
    wrong = await delete_me(client, user, "not my password")
    assert wrong.status_code == 401
    assert wrong.json()["error"]["code"] == "invalid_password"
    assert (await client.get("/v1/me", headers=user.headers)).status_code == 200
    assert (await delete_me(client, user)).status_code == 204


async def test_delete_me_is_rate_limited(client: AsyncClient) -> None:
    user = await register(client)
    for _ in range(20):  # tests.conftest.make_settings
        assert (await delete_me(client, user, "wrong password")).status_code == 401
    assert (await delete_me(client, user)).status_code == 429


# --- 15. a password change invalidates older access tokens ------------------------------


async def test_password_reset_rejects_access_tokens_issued_before_it(
    client: AsyncClient, app_and_engine: tuple[Any, AsyncEngine]
) -> None:
    tokens = app_and_engine[0].state.tokens
    user = await register(client)
    old = tokens.issue_access(uuid.UUID(user.id), now=datetime.now(UTC) - timedelta(seconds=10))
    old_headers = {"Authorization": f"Bearer {old}"}
    assert (await client.get("/v1/me", headers=old_headers)).status_code == 200

    await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    code = last_code(client, user.email, "password_reset")
    resp = await client.post(
        "/v1/auth/password-reset/confirm",
        json={"email": user.email, "code": code, "new_password": "brand new password"},
    )
    assert resp.status_code == 204
    assert (await client.get("/v1/me", headers=old_headers)).status_code == 401

    login = await client.post(
        "/v1/auth/login", json={"email": user.email, "password": "brand new password"}
    )
    fresh = {"Authorization": f"Bearer {login.json()['access_token']}"}
    assert (await client.get("/v1/me", headers=fresh)).status_code == 200


# --- 16. account deletion erases everything ---------------------------------------------


async def _rows_mentioning(engine: AsyncEngine, needles: list[str]) -> dict[str, int]:
    found: dict[str, int] = {}
    async with engine.connect() as conn:
        tables = (
            await conn.execute(
                text(
                    "SELECT tablename FROM pg_tables WHERE schemaname = 'public' "
                    "AND tablename <> 'alembic_version'"
                )
            )
        ).scalars()
        for table in list(tables):
            for needle in needles:
                n = (
                    await conn.execute(
                        text(f"SELECT count(*) FROM {table} t WHERE t::text LIKE :n"),  # noqa: S608
                        {"n": f"%{needle}%"},
                    )
                ).scalar_one()
                if n:
                    found[f"{table}:{needle}"] = n
    return found


async def test_account_deletion_erases_all_owned_rows(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    other = await register(client)
    other_med = await create_medication(client, other)
    pid = str(uuid.uuid4())
    await client.post(
        "/v1/profiles",
        json={"id": pid, "display_name": "Grandma", "timezone": "UTC"},
        headers=user.headers,
    )
    med = await create_medication(client, user, profile_id=pid)
    sched = await create_schedule(client, user, med["id"])
    taken, undo = str(uuid.uuid4()), str(uuid.uuid4())
    await push(
        client,
        user,
        "phone-1",
        [
            mut(
                "dose_event",
                "upsert",
                taken,
                {"medication_id": med["id"], "type": "taken", "at": datetime.now(UTC).isoformat()},
            ),
            mut(
                "dose_event",
                "upsert",
                undo,
                {
                    "medication_id": med["id"],
                    "type": "undo",
                    "target_event_id": taken,
                    "at": datetime.now(UTC).isoformat(),
                },
            ),
        ],
    )
    await client.post("/v1/auth/password-reset/request", json={"email": user.email})
    # Links in both directions: a viewer of the managed profile (a co-guardian would inherit
    # it, see test_managed_archive), an open invite, and the user as an editor on someone
    # else's profile (that invite is consumed by them).
    relative = await register(client)
    guardian_grant = await link_accounts(client, user, relative, "viewer", pid)
    open_invite = await create_invite(client, user)
    incoming_grant = await link_accounts(client, other, user, "editor")
    needles = [
        user.id,
        user.self_profile_id,
        pid,
        med["id"],
        sched["id"],
        taken,
        undo,
        user.email,
        guardian_grant["id"],
        open_invite["id"],
        token_of(open_invite),
        incoming_grant["id"],
    ]
    assert await _rows_mentioning(engine, needles)

    # The request alone erases nothing: the data stays, blocked, for the grace period.
    assert (await request_deletion(client, user)).status_code == 204
    assert await _rows_mentioning(engine, needles)
    before_grace_ends = await run_erase_job(
        client, datetime.now(UTC) + timedelta(days=29)
    )  # erase_after is request + 30 days - 1 hour
    assert before_grace_ends.erased == 0
    assert await _rows_mentioning(engine, needles)

    report = await run_erase_job(client, datetime.now(UTC) + timedelta(days=31))
    assert report.erased == 1
    assert await _rows_mentioning(engine, needles) == {}
    # Other accounts are untouched.
    got = await client.get(f"/v1/medications/{other_med['id']}", headers=other.headers)
    assert got.status_code == 200


async def test_dose_events_stay_append_only_outside_the_purge(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    eid = str(uuid.uuid4())
    await push(
        client,
        user,
        "d",
        [
            mut(
                "dose_event",
                "upsert",
                eid,
                {"medication_id": med["id"], "type": "taken", "at": datetime.now(UTC).isoformat()},
            )
        ],
    )
    async with engine.connect() as conn:
        with pytest.raises(Exception, match="append-only"):
            await conn.execute(text("DELETE FROM dose_events"))
        await conn.rollback()
        # The purge flag only unlocks DELETE, never UPDATE, and only for its transaction.
        await conn.execute(text("SELECT set_config('pillpal.purge', 'on', true)"))
        with pytest.raises(Exception, match="append-only"):
            await conn.execute(text("UPDATE dose_events SET note = 'x'"))
        await conn.rollback()
        await conn.execute(text("SELECT set_config('pillpal.purge', 'on', true)"))
        assert (await conn.execute(text("DELETE FROM dose_events"))).rowcount == 1
        await conn.rollback()
        with pytest.raises(Exception, match="append-only"):
            await conn.execute(text("DELETE FROM dose_events"))
        await conn.rollback()


# --- 17. tombstones hold no medical content ---------------------------------------------


async def test_tombstones_do_not_retain_medical_content(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    await client.post(
        "/v1/profiles",
        json={"id": pid, "display_name": "Grandma Secret", "timezone": "UTC"},
        headers=user.headers,
    )
    rich = {
        "name": "Secretol",
        "form": "tablet",
        "strength_text": "100 mg",
        "notes": "private note",
        "stock_count": "30",
        "stock_unit": "tablet",
        "low_stock_days": 5,
    }
    med1 = await create_medication(client, user, profile_id=pid, **rich)
    sched1 = await create_schedule(client, user, med1["id"])
    med2 = await create_medication(client, user, **rich)
    sched2 = await create_schedule(client, user, med2["id"], daily_rule(("21:00",)))
    med3 = await create_medication(client, user, **rich)
    # Sync delete (cascades to sched2), REST delete, REST profile delete (cascades).
    await push(client, user, "d", [mut("medication", "delete", med2["id"], None)])
    assert (
        await client.delete(f"/v1/medications/{med3['id']}", headers=user.headers)
    ).status_code == 204
    assert (await client.delete(f"/v1/profiles/{pid}", headers=user.headers)).status_code == 204

    async with engine.connect() as conn:
        profile = (
            await conn.execute(
                text("SELECT display_name, deleted_at FROM profiles WHERE id = :i"), {"i": pid}
            )
        ).one()
        assert profile.deleted_at is not None
        assert profile.display_name is None
        for mid in (med1["id"], med2["id"], med3["id"]):
            row = (
                await conn.execute(
                    text(
                        "SELECT name, form, strength_text, notes, stock_count, stock_unit, "
                        "low_stock_days, deleted_at FROM medications WHERE id = :i"
                    ),
                    {"i": mid},
                )
            ).one()
            assert row.deleted_at is not None
            assert tuple(row)[:7] == (None,) * 7, mid
        for sid in (sched1["id"], sched2["id"]):
            row = (
                await conn.execute(
                    text("SELECT rule IS NULL AS erased, deleted_at FROM schedules WHERE id = :i"),
                    {"i": sid},
                )
            ).one()
            assert row.deleted_at is not None
            assert row.erased is True, sid


async def test_schema_requires_content_on_live_rows_and_none_on_tombstones(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(client, user)
    sched = await create_schedule(client, user, med["id"])
    statements = [
        ("UPDATE profiles SET display_name = NULL WHERE id = :p", {"p": user.self_profile_id}),
        ("UPDATE medications SET name = NULL WHERE id = :p", {"p": med["id"]}),
        ("UPDATE schedules SET rule = NULL WHERE id = :p", {"p": sched["id"]}),
        ("UPDATE medications SET deleted_at = now() WHERE id = :p", {"p": med["id"]}),
        ("UPDATE schedules SET deleted_at = now() WHERE id = :p", {"p": sched["id"]}),
    ]
    async with engine.connect() as conn:
        for sql, params in statements:
            with pytest.raises(Exception, match="check"):
                await conn.execute(text(sql), params)
            await conn.rollback()


async def test_sync_upsert_of_tombstoned_medication_keeps_it_erased(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    mid = str(uuid.uuid4())
    await push(
        client, user, "d", [mut("medication", "upsert", mid, med_data(user.self_profile_id))]
    )
    await push(client, user, "d", [mut("medication", "delete", mid, None, 1)])
    zombie = await push(
        client, user, "d", [mut("medication", "upsert", mid, med_data(user.self_profile_id), 2)]
    )
    assert zombie[0]["code"] == "deleted"
    async with engine.connect() as conn:
        name = (
            await conn.execute(text("SELECT name FROM medications WHERE id = :i"), {"i": mid})
        ).scalar_one()
    assert name is None
