"""``python -m app.admin entitlement`` on real PostgreSQL (ADR 0018 section 5)."""

from __future__ import annotations

import io
import os
import sys
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy.exc import DBAPIError
from sqlalchemy.ext.asyncio import AsyncEngine

from app.admin.cli import run_admin
from app.services.admin_audit import Operator, current_operator, os_user_name
from tests.conftest import make_settings
from tests.entitlement_helpers import (
    OPERATOR,
    CliRun,
    insert_audit,
    insert_entitlement,
    rows,
    run_cli,
)
from tests.grace_helpers import request_deletion
from tests.helpers import User, register
from tests.test_config_and_migrations import _recreate_db

GRANT = ("entitlement", "grant", "--kind", "ads_removed", "--actor", "ops-1")


async def grant(email: str, *extra: str, kind: str = "ads_removed") -> CliRun:
    argv = ("entitlement", "grant", "--kind", kind, "--actor", "ops-1", *extra)
    return await run_cli(*argv, stdin=email + "\n")


async def entitlements_of(engine: AsyncEngine, user: User) -> list[dict[str, object]]:
    return await rows(
        engine,
        "SELECT kind, source, source_ref, expires_at, revoked_at FROM entitlements "
        "WHERE user_id = :u ORDER BY granted_at",
        u=uuid.UUID(user.id),
    )


async def test_grant_creates_an_admin_grant_and_one_audit_row(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    result = await grant(user.email)

    assert result.code == 0, result.err
    assert user.id in result.out
    [row] = await entitlements_of(engine, user)
    assert (row["kind"], row["source"], row["source_ref"]) == ("ads_removed", "admin_grant", None)
    assert row["expires_at"] is None
    assert row["revoked_at"] is None
    [audit] = await rows(engine, "SELECT * FROM admin_audit")
    assert audit["action"] == "entitlement_grant"
    assert str(audit["target_user_id"]) == user.id
    assert audit["kind"] == "ads_removed"
    assert (audit["actor"], audit["os_user"], audit["host"]) == (
        OPERATOR.actor,
        OPERATOR.os_user,
        OPERATOR.host,
    )
    [entitlement] = await rows(engine, "SELECT id FROM entitlements")
    assert audit["object_id"] == entitlement["id"]
    assert str(audit["object_id"]) != user.id  # never a user id
    # The grant is visible to the account through the API.
    body = (await client.get("/v1/me/entitlements", headers=user.headers)).json()
    assert body["ads_removed"] is True


async def test_the_email_is_matched_case_insensitively_and_trimmed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client, email="Mixed.Case@Example.com")
    result = await run_cli(*GRANT, stdin=f"  {user.email.upper()}  \nsecond line ignored\n")
    assert result.code == 0, result.err
    assert len(await entitlements_of(engine, user)) == 1


async def test_grant_with_an_expiry(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    expires = datetime.now(UTC) + timedelta(days=30)
    result = await grant(user.email, "--expires", expires.isoformat(), kind="limits_lifted")
    assert result.code == 0, result.err
    [row] = await entitlements_of(engine, user)
    assert row["kind"] == "limits_lifted"
    assert row["expires_at"] == expires


async def test_replaying_a_grant_is_a_no_op(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    first = await grant(user.email)
    second = await grant(user.email)

    assert first.code == second.code == 0
    assert "already granted" in second.out
    assert len(await entitlements_of(engine, user)) == 1
    assert len(await rows(engine, "SELECT id FROM admin_audit")) == 1


async def test_the_same_grant_with_another_expiry_or_kind_is_a_new_grant(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    later = (datetime.now(UTC) + timedelta(days=5)).isoformat()
    assert (await grant(user.email)).code == 0
    assert (await grant(user.email, "--expires", later)).code == 0
    assert (await grant(user.email, kind="limits_lifted")).code == 0
    assert len(await entitlements_of(engine, user)) == 3
    assert len(await rows(engine, "SELECT id FROM admin_audit")) == 3


async def test_a_grant_after_a_revoke_is_a_new_grant(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    assert (await grant(user.email)).code == 0
    revoke = await run_cli(
        "entitlement",
        "revoke",
        "--account-id",
        user.id,
        "--kind",
        "ads_removed",
        "--actor",
        "ops-1",
    )
    assert revoke.code == 0, revoke.err
    assert (await grant(user.email)).code == 0
    states = [r["revoked_at"] is None for r in await entitlements_of(engine, user)]
    assert states == [False, True]


async def test_an_unknown_account_exits_two_and_writes_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    await register(client)
    missing = "nobody.synthetic@example.com"
    result = await grant(missing)
    assert result.code == 2
    assert missing not in result.out + result.err
    assert await rows(engine, "SELECT id FROM entitlements") == []
    assert await rows(engine, "SELECT id FROM admin_audit") == []


async def test_a_pending_deletion_account_is_refused_for_grant_but_can_be_revoked(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await insert_entitlement(engine, user.id)
    assert (await request_deletion(client, user)).status_code == 204

    assert (await grant(user.email, kind="limits_lifted")).code == 2
    assert len(await entitlements_of(engine, user)) == 1
    assert await rows(engine, "SELECT id FROM admin_audit") == []

    revoke = await run_cli(
        "entitlement",
        "revoke",
        "--account-id",
        user.id,
        "--kind",
        "ads_removed",
        "--actor",
        "ops-1",
    )
    assert revoke.code == 0, revoke.err
    [row] = await entitlements_of(engine, user)
    assert row["revoked_at"] is not None
    assert len(await rows(engine, "SELECT id FROM admin_audit")) == 1


async def test_revoke_sets_revoked_at_for_every_live_row_of_the_kind(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user, other = await register(client), await register(client)
    promo = await insert_entitlement(engine, user.id, "ads_removed", "promo")
    purchase = await insert_entitlement(engine, user.id, "ads_removed", "purchase")
    kept = await insert_entitlement(engine, user.id, "limits_lifted", "promo")
    others = await insert_entitlement(engine, other.id, "ads_removed", "promo")

    result = await run_cli(
        "entitlement",
        "revoke",
        "--account-id",
        user.id,
        "--kind",
        "ads_removed",
        "--actor",
        "ops-1",
    )

    assert result.code == 0, result.err
    assert "revoked 2" in result.out
    state = {
        r["id"]: r["revoked_at"] is not None
        for r in await rows(engine, "SELECT id, revoked_at FROM entitlements")
    }
    assert state == {promo: True, purchase: True, kept: False, others: False}
    audits = await rows(engine, "SELECT * FROM admin_audit")
    assert {a["object_id"] for a in audits} == {promo, purchase}
    assert {a["action"] for a in audits} == {"entitlement_revoke"}
    assert {str(a["target_user_id"]) for a in audits} == {user.id}
    body = (await client.get("/v1/me/entitlements", headers=user.headers)).json()
    assert body["ads_removed"] is False


async def test_revoking_nothing_is_a_quiet_success(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    argv = ("entitlement", "revoke", "--account-id", user.id, "--kind", "ads_removed")
    first = await run_cli(*argv, "--actor", "ops-1")
    assert first.code == 0
    assert "revoked 0" in first.out
    assert await rows(engine, "SELECT id FROM admin_audit") == []


async def test_revoking_an_unknown_account_id_exits_two(client: AsyncClient) -> None:
    result = await run_cli(
        "entitlement",
        "revoke",
        "--account-id",
        str(uuid.uuid4()),
        "--kind",
        "ads_removed",
        "--actor",
        "ops-1",
    )
    assert result.code == 2


async def test_nothing_in_the_output_or_the_audit_holds_the_email(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client, email="private.person@example.com")
    for run in (await grant(user.email), await grant(user.email)):
        assert run.code == 0
        assert user.email not in run.out + run.err
        assert "private.person" not in run.out + run.err
    audit_text = str(await rows(engine, "SELECT * FROM admin_audit"))
    assert "private.person" not in audit_text
    assert "example.com" not in audit_text
    assert "@" not in audit_text


@pytest.mark.parametrize(
    "argv",
    [
        (),
        ("entitlement",),
        ("entitlement", "grant"),
        ("entitlement", "grant", "--kind", "bogus", "--actor", "ops-1"),
        ("entitlement", "grant", "--kind", "ads_removed"),  # no actor
        ("entitlement", "grant", "--kind", "ads_removed", "--actor", ""),
        ("entitlement", "grant", "--kind", "ads_removed", "--actor", "a" * 65),
        ("entitlement", "grant", "--kind", "ads_removed", "--actor", "me@example.com"),
        ("entitlement", "grant", "--kind", "ads_removed", "--actor", "tab\there"),
        ("entitlement", "grant", "--kind", "ads_removed", "--actor", "nul\x00byte"),
        ("entitlement", "grant", "--kind", "ads_removed", "--actor", "x", "--expires", "nonsense"),
        # An expiry without an offset is ambiguous.
        (
            "entitlement",
            "grant",
            "--kind",
            "ads_removed",
            "--actor",
            "x",
            "--expires",
            "2999-01-01",
        ),
        ("entitlement", "revoke", "--kind", "ads_removed", "--actor", "x"),
        ("entitlement", "revoke", "--account-id", "nope", "--kind", "ads_removed", "--actor", "x"),
    ],
)
async def test_usage_errors_exit_two(engine: AsyncEngine, argv: tuple[str, ...]) -> None:
    result = await run_cli(*argv, stdin="someone@example.com\n")
    assert result.code == 2
    assert "someone@example.com" not in result.out + result.err
    assert "me@example.com" not in result.out + result.err
    assert await rows(engine, "SELECT id FROM entitlements") == []


async def test_a_missing_email_on_stdin_or_a_past_expiry_exits_two(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    assert (await run_cli(*GRANT, stdin="")).code == 2
    assert (await run_cli(*GRANT, stdin="\n")).code == 2
    past = (datetime.now(UTC) - timedelta(days=1)).isoformat()
    assert (await grant(user.email, "--expires", past)).code == 2
    assert await rows(engine, "SELECT id FROM entitlements") == []


async def test_help_exits_zero() -> None:
    assert (await run_cli("--help")).code == 0


def test_the_actor_is_never_an_email_and_the_operator_fields_are_plain() -> None:
    with pytest.raises(ValueError, match="actor"):
        Operator("x@example.com")
    with pytest.raises(ValueError, match="actor"):
        Operator("")
    operator = current_operator("ops-1")
    assert operator.actor == "ops-1"
    assert operator.os_user
    assert operator.host
    assert "@" not in operator.os_user + operator.host


async def test_the_audit_table_refuses_an_email_like_actor(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    with pytest.raises(DBAPIError, match="actor"):
        await insert_audit(engine, None, None, actor="someone@example.com")
    with pytest.raises(DBAPIError, match="actor"):
        await insert_audit(engine, None, None, actor="")


async def test_a_malformed_email_on_stdin_exits_two(engine: AsyncEngine) -> None:
    for line in ("not-an-email", "a@", "two words@example.com"):
        result = await run_cli(*GRANT, stdin=line + "\n")
        assert result.code == 2
    assert await rows(engine, "SELECT id FROM entitlements") == []


async def test_a_database_failure_prints_the_error_type_and_never_the_email(
    capsys: pytest.CaptureFixture[str],
) -> None:
    # A real database without the schema: the lookup fails with the e-mail as a bound parameter.
    url = await _recreate_db("pillpal_test_admin_cli_empty")
    email = "never.print.me@example.com"
    out, err = io.StringIO(), io.StringIO()
    code = await run_admin(
        GRANT,
        stdin=io.StringIO(email + "\n"),
        settings=make_settings(database_url=url),
        stdout=out,
        stderr=err,
        operator=OPERATOR,
    )
    assert code == 1
    assert "database error: " in err.getvalue()
    captured = capsys.readouterr()
    for text in (out.getvalue(), err.getvalue(), captured.out, captured.err):
        assert email not in text
        assert "never.print.me" not in text


@pytest.mark.skipif(sys.platform == "win32", reason="passwd database")
def test_the_os_user_comes_from_the_passwd_entry_not_the_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    import pwd

    expected = pwd.getpwuid(os.geteuid()).pw_name
    for name in ("USER", "LOGNAME", "USERNAME"):
        monkeypatch.setenv(name, "forged-operator")
    assert os_user_name() == expected
    assert current_operator("ops-1").os_user == expected


async def test_the_audit_table_refuses_a_non_printable_actor(engine: AsyncEngine) -> None:
    for actor in ("tab\there", "new\nline"):
        with pytest.raises(DBAPIError, match="actor"):
            await insert_audit(engine, None, None, actor=actor)


def test_the_operator_refuses_a_non_printable_actor() -> None:
    with pytest.raises(ValueError, match="actor"):
        Operator("tab\there")
