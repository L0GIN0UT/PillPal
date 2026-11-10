"""Consent records (Phase 5.2a): registration, /v1/me/consents, withdrawal, erasure."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.grace_helpers import delete_and_erase, pending_login, request_deletion, restore
from tests.helpers import DEFAULT_PASSWORD, User, outbox, register, register_unverified, verify

BASELINE = ("health_data", "terms", "privacy")
BASELINE_BODY = [{"kind": kind, "version": 1} for kind in BASELINE]


@pytest.fixture
def required(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> None:
    monkeypatch.setattr(settings, "consent_required_at_registration", True)


@pytest.fixture
def terms_v2(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> None:
    monkeypatch.setattr(settings, "consent_versions_terms", [1, 2])


async def post_register(client: AsyncClient, email: str, **extra: Any) -> Response:
    return await client.post(
        "/v1/auth/register",
        json={"email": email, "password": DEFAULT_PASSWORD, "region": "ru", **extra},
    )


async def overview(client: AsyncClient, user: User) -> dict[str, Any]:
    resp = await client.get("/v1/me/consents", headers=user.headers)
    assert resp.status_code == 200, resp.text
    return dict(resp.json())


async def accept(client: AsyncClient, user: User, kind: str, version: int = 1) -> Response:
    return await client.post(
        "/v1/me/consents", json={"kind": kind, "version": version}, headers=user.headers
    )


async def count_rows(engine: AsyncEngine, email: str | None = None) -> int:
    sql = "SELECT count(*) FROM consents"
    params: dict[str, Any] = {}
    if email is not None:
        sql += " WHERE user_id IN (SELECT id FROM users WHERE lower(email) = :e)"
        params["e"] = email.lower()
    async with engine.connect() as conn:
        return int((await conn.execute(text(sql), params)).scalar_one())


async def user_count(engine: AsyncEngine, email: str) -> int:
    async with engine.connect() as conn:
        result = await conn.execute(
            text("SELECT count(*) FROM users WHERE lower(email) = :e"), {"e": email.lower()}
        )
        return int(result.scalar_one())


# --- registration -----------------------------------------------------------------------------


async def test_registration_without_consents_records_nothing_while_not_required(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    body = await overview(client, user)
    assert body["records"] == []
    assert body["missing"] == list(BASELINE)
    assert body["current"] == {
        "health_data": 1,
        "terms": 1,
        "privacy": 1,
        "catalog_contribution": 1,
    }
    assert await count_rows(engine) == 0


async def test_registration_records_the_given_consents_with_source_registration(
    client: AsyncClient,
) -> None:
    email = await register_unverified(client, consents=BASELINE_BODY)
    tokens = await verify(client, email)
    user = User("", email, DEFAULT_PASSWORD, tokens["access_token"], tokens["refresh_token"], "")
    body = await overview(client, user)
    assert sorted((r["kind"], r["version"], r["source"]) for r in body["records"]) == sorted(
        (kind, 1, "registration") for kind in BASELINE
    )
    assert all(r["withdrawn_at"] is None and r["accepted_at"] for r in body["records"])
    assert body["missing"] == []


async def test_the_catalog_contribution_is_refused_at_registration(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    email = "contribution@example.com"
    resp = await post_register(
        client, email, consents=[*BASELINE_BODY, {"kind": "catalog_contribution", "version": 1}]
    )
    assert (resp.status_code, resp.json()["error"]["code"]) == (422, "unsupported_consent_kind")
    assert await user_count(engine, email) == 0
    assert await count_rows(engine) == 0


async def test_required_registration_refuses_missing_consents_and_creates_nothing(
    client: AsyncClient, engine: AsyncEngine, required: None
) -> None:
    email = "needs-consent@example.com"
    refused: list[dict[str, Any]] = [{}, {"consents": []}, {"consents": BASELINE_BODY[:2]}]
    for extra in refused:
        resp = await post_register(client, email, **extra)
        assert resp.status_code == 422, resp.text
        assert resp.json()["error"]["code"] == "consent_required"
    assert await user_count(engine, email) == 0
    assert outbox(client) == []
    ok = await post_register(client, email, consents=BASELINE_BODY)
    assert ok.status_code == 202
    assert await count_rows(engine, email) == 3


async def test_present_consents_are_checked_even_when_not_required(client: AsyncClient) -> None:
    resp = await post_register(client, "partial@example.com", consents=BASELINE_BODY[:1])
    assert (resp.status_code, resp.json()["error"]["code"]) == (422, "consent_required")


async def test_an_unknown_or_old_version_is_refused(client: AsyncClient, terms_v2: None) -> None:
    unknown = [*BASELINE_BODY[:2], {"kind": "privacy", "version": 5}]
    resp = await post_register(client, "unknown-version@example.com", consents=unknown)
    assert (resp.status_code, resp.json()["error"]["code"]) == (422, "unsupported_consent_version")
    # Version 1 of the terms is known but not the current one any more.
    resp = await post_register(client, "old-version@example.com", consents=BASELINE_BODY)
    assert (resp.status_code, resp.json()["error"]["code"]) == (422, "consent_required")
    current = [*BASELINE_BODY[:1], {"kind": "terms", "version": 2}, BASELINE_BODY[2]]
    assert (await post_register(client, "new@example.com", consents=current)).status_code == 202


@pytest.mark.parametrize(
    "consents",
    [
        [*BASELINE_BODY, {"kind": "terms", "version": 1}],  # a kind twice
        [{"kind": "terms", "version": 1, "extra": True}],
        [{"kind": "ads", "version": 1}],
        [{"kind": "terms", "version": 0}],
        [{"kind": "terms", "version": "1"}],
        [{"kind": "terms", "version": True}],
        [*BASELINE_BODY, {"kind": "catalog_contribution", "version": 1}, BASELINE_BODY[0]],
        "terms",
    ],
)
async def test_malformed_consents_are_a_validation_error(
    client: AsyncClient, consents: Any
) -> None:
    resp = await post_register(client, "malformed@example.com", consents=consents)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


async def test_extra_registration_fields_are_still_refused(client: AsyncClient) -> None:
    resp = await post_register(client, "extra@example.com", consents=BASELINE_BODY, admin=True)
    assert resp.status_code == 422


async def test_a_known_address_gets_the_same_answer_and_no_rows(
    client: AsyncClient, engine: AsyncEngine, required: None
) -> None:
    email = await register_unverified(client, consents=BASELINE_BODY)
    await verify(client, email)
    assert await count_rows(engine, email) == 3
    outbox_before = len(outbox(client))

    again = await post_register(client, email, consents=BASELINE_BODY)
    assert again.status_code == 202
    assert again.json() == {"status": "verification_sent"}
    assert await count_rows(engine, email) == 3  # nothing recorded for the known account
    assert len(outbox(client)) == outbox_before + 1  # the "account exists" notice

    # The refusal does not depend on whether the address is known: no enumeration.
    known = await post_register(client, email)
    unknown = await post_register(client, "nobody-here@example.com")
    assert known.status_code == unknown.status_code == 422
    assert known.json() == unknown.json()


async def test_a_known_address_without_consents_keeps_its_rows_untouched(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    assert (await accept(client, user, "terms")).status_code == 201
    before = await count_rows(engine, user.email)
    resp = await post_register(client, user.email, consents=BASELINE_BODY)
    assert resp.status_code == 202
    assert await count_rows(engine, user.email) == before == 1


# --- features -----------------------------------------------------------------------------------


async def test_features_list_the_kinds_registration_requires(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    off = await client.get("/v1/me/features", headers=user.headers)
    assert off.json()["consent_required_kinds"] == []
    monkeypatch.setattr(settings, "consent_required_at_registration", True)
    on = await client.get("/v1/me/features", headers=user.headers)
    assert on.json()["consent_required_kinds"] == list(BASELINE)


# --- GET / POST -------------------------------------------------------------------------------


async def test_accept_creates_then_replays(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    first = await accept(client, user, "health_data")
    assert first.status_code == 201, first.text
    record = first.json()
    assert (record["kind"], record["version"], record["source"]) == ("health_data", 1, "in_app")
    assert record["withdrawn_at"] is None
    assert set(record) == {"id", "kind", "version", "source", "accepted_at", "withdrawn_at"}

    replay = await accept(client, user, "health_data")
    assert replay.status_code == 200
    assert replay.json() == record
    assert await count_rows(engine) == 1

    body = await overview(client, user)
    assert [r["id"] for r in body["records"]] == [record["id"]]
    assert body["missing"] == ["terms", "privacy"]
    for kind in ("terms", "privacy"):
        assert (await accept(client, user, kind)).status_code == 201
    assert (await overview(client, user))["missing"] == []


async def test_a_new_version_makes_the_kind_missing_until_accepted(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    user = await register(client)
    for kind in BASELINE:
        assert (await accept(client, user, kind)).status_code == 201
    assert (await overview(client, user))["missing"] == []

    monkeypatch.setattr(settings, "consent_versions_terms", [1, 2])
    body = await overview(client, user)
    assert body["missing"] == ["terms"]
    assert body["current"]["terms"] == 2
    assert len(body["records"]) == 3  # the old acceptance stays on record
    assert (await accept(client, user, "terms", 2)).status_code == 201
    body = await overview(client, user)
    assert body["missing"] == []
    assert len(body["records"]) == 4


async def test_only_the_current_version_can_be_accepted(
    client: AsyncClient, terms_v2: None
) -> None:
    user = await register(client)
    for version in (1, 3):
        resp = await accept(client, user, "terms", version)
        assert (resp.status_code, resp.json()["error"]["code"]) == (
            422,
            "unsupported_consent_version",
        )
    assert (await accept(client, user, "terms", 2)).status_code == 201
    assert (await overview(client, user))["records"][0]["version"] == 2


async def test_the_catalog_contribution_cannot_be_given_here(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    resp = await accept(client, user, "catalog_contribution")
    assert (resp.status_code, resp.json()["error"]["code"]) == (422, "unsupported_consent_kind")
    assert await count_rows(engine) == 0


@pytest.mark.parametrize(
    "body",
    [
        {"kind": "terms"},
        {"version": 1},
        {"kind": "ads", "version": 1},
        {"kind": "terms", "version": 0},
        {"kind": "terms", "version": "1"},
        {"kind": "terms", "version": 1, "source": "registration"},
        {"kind": "terms", "version": 1, "user_id": str(uuid.uuid4())},
    ],
)
async def test_accept_validates_the_body(client: AsyncClient, body: dict[str, Any]) -> None:
    user = await register(client)
    resp = await client.post("/v1/me/consents", json=body, headers=user.headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


async def test_consents_need_authentication(client: AsyncClient) -> None:
    body = {"kind": "terms", "version": 1}
    for method, path, payload in (
        ("GET", "/v1/me/consents", None),
        ("POST", "/v1/me/consents", body),
        ("POST", "/v1/me/consents/withdraw", {"kind": "terms"}),
    ):
        resp = await client.request(method, path, json=payload)
        assert resp.status_code == 401, (path, resp.text)
        resp = await client.request(
            method, path, json=payload, headers={"Authorization": "Bearer nonsense"}
        )
        assert resp.status_code == 401, path


async def test_records_are_private_to_their_account(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    alice, bob = await register(client), await register(client)
    mine = (await accept(client, alice, "terms")).json()
    assert (await overview(client, bob))["records"] == []
    # Bob accepting the same version creates his own row; Alice's record is not reused.
    theirs = (await accept(client, bob, "terms")).json()
    assert theirs["id"] != mine["id"]
    assert [r["id"] for r in (await overview(client, alice))["records"]] == [mine["id"]]
    assert await count_rows(engine) == 2


async def test_accepting_is_rate_limited_per_account(client: AsyncClient) -> None:
    user = await register(client)
    limit = 20  # tests.conftest.make_settings
    for _ in range(limit):
        assert (await accept(client, user, "terms")).status_code in (200, 201)
    blocked = await accept(client, user, "terms")
    assert blocked.status_code == 429
    assert "Retry-After" in blocked.headers
    other = await register(client)
    assert (await accept(client, other, "terms")).status_code == 201


async def test_a_pending_deletion_account_cannot_accept(client: AsyncClient) -> None:
    user = await register(client)
    assert (await request_deletion(client, user)).status_code == 204
    assert (await accept(client, user, "terms")).status_code == 401


# --- withdrawal -------------------------------------------------------------------------------


@pytest.mark.parametrize("kind", BASELINE)
async def test_baseline_consents_are_withdrawn_by_deleting_the_account(
    client: AsyncClient, engine: AsyncEngine, kind: str
) -> None:
    user = await register(client)
    await accept(client, user, kind)
    resp = await client.post("/v1/me/consents/withdraw", json={"kind": kind}, headers=user.headers)
    assert (resp.status_code, resp.json()["error"]["code"]) == (
        409,
        "withdraw_via_account_deletion",
    )
    record = (await overview(client, user))["records"][0]
    assert record["withdrawn_at"] is None
    assert await count_rows(engine) == 1


async def test_withdrawing_the_catalog_contribution_is_not_available_yet(
    client: AsyncClient,
) -> None:
    user = await register(client)
    resp = await client.post(
        "/v1/me/consents/withdraw", json={"kind": "catalog_contribution"}, headers=user.headers
    )
    assert resp.status_code == 501
    assert resp.json()["error"]["code"] == "not_implemented"


@pytest.mark.parametrize("body", [{}, {"kind": "ads"}, {"kind": "terms", "version": 1}])
async def test_withdraw_validates_the_body(client: AsyncClient, body: dict[str, Any]) -> None:
    user = await register(client)
    resp = await client.post("/v1/me/consents/withdraw", json=body, headers=user.headers)
    assert resp.status_code == 422


# --- erasure ----------------------------------------------------------------------------------


async def test_erasing_an_account_deletes_its_consents_and_only_its_own(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    leaving, staying = await register(client), await register(client)
    for kind in BASELINE:
        await accept(client, leaving, kind)
    survivor = (await accept(client, staying, "terms")).json()
    assert await count_rows(engine) == 4

    await delete_and_erase(client, leaving)

    async with engine.connect() as conn:
        left = (await conn.execute(text("SELECT id FROM consents"))).scalars().all()
    assert [str(i) for i in left] == [survivor["id"]]


# --- deletion and restore ---------------------------------------------------------------------


async def test_a_deletion_request_withdraws_the_baseline_and_a_restore_keeps_it_so(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    for kind in BASELINE:
        assert (await accept(client, user, kind)).status_code == 201
    other = await register(client)
    await accept(client, other, "terms")

    assert (await request_deletion(client, user)).status_code == 204

    async with engine.connect() as conn:
        rows = (
            await conn.execute(
                text(
                    "SELECT kind, withdrawn_at >= accepted_at FROM consents "
                    "WHERE user_id = :u AND withdrawn_at IS NOT NULL"
                ),
                {"u": uuid.UUID(user.id)},
            )
        ).all()
        untouched = (
            await conn.execute(
                text("SELECT count(*) FROM consents WHERE user_id = :u AND withdrawn_at IS NULL"),
                {"u": uuid.UUID(other.id)},
            )
        ).scalar_one()
    assert sorted(kind for kind, _ in rows) == sorted(BASELINE)
    assert all(ok for _, ok in rows)
    assert untouched == 1

    ticket, code = await pending_login(client, user)
    restored = await restore(client, ticket, code)
    assert restored.status_code == 200, restored.text
    back = User(
        user.id,
        user.email,
        user.password,
        restored.json()["access_token"],
        restored.json()["refresh_token"],
        user.self_profile_id,
    )
    body = await overview(client, back)
    assert body["missing"] == list(BASELINE)
    assert all(r["withdrawn_at"] is not None for r in body["records"])
    # Accepting again gives a fresh active record next to the withdrawn one.
    assert (await accept(client, back, "terms")).status_code == 201
    assert (await overview(client, back))["missing"] == ["health_data", "privacy"]
