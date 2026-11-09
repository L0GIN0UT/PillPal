"""Admin endpoints on the private listener (ADR 0014 section 5) and the trust boundary."""

from __future__ import annotations

import uuid
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.api.seed import Seed
from tests.consensus.conftest import (
    ADMIN_SECOND_SECRET,
    ADMIN_SECRET,
    GTIN,
    OTHER_GTIN,
    RU_SECRET,
    Candidates,
    gtin14,
    private_app_client,
    private_settings,
)
from tests.consensus.helpers import item, put

RESTRICTED = "02000000000008"


def admin(secret: str = ADMIN_SECRET) -> dict[str, str]:
    return {"Authorization": f"Bearer {secret}"}


async def resolve(
    client: AsyncClient,
    action: str,
    product: uuid.UUID | None = None,
    *,
    gtin: str = GTIN,
    secret: str = ADMIN_SECRET,
) -> Any:
    body: dict[str, Any] = {"action": action}
    if product is not None:
        body["product_id"] = str(product)
    return await client.post(f"/admin/v1/gtins/{gtin}:resolve", json=body, headers=admin(secret))


async def audit(engine: AsyncEngine) -> list[tuple[str, str, str, uuid.UUID | None]]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT admin_name, action, gtin, product_id FROM catalog.admin_audit ORDER BY id")
        )
        return [(r.admin_name, r.action, r.gtin, r.product_id) for r in rows]


# --- the trust boundary ---------------------------------------------------------------------


async def test_the_public_app_has_no_admin_or_internal_routes(client: AsyncClient) -> None:
    for method, path in (
        ("GET", "/admin/v1/disputes"),
        ("GET", "/admin/v1/import-runs"),
        ("POST", f"/admin/v1/gtins/{GTIN}:resolve"),
        ("PUT", "/internal/v1/regions/ru/gtin-confirmations"),
    ):
        answer = await client.request(method, path, headers=admin(), json={})
        assert answer.status_code == 404, path
    paths = (await client.get("/openapi.json")).json()["paths"]
    assert [p for p in paths if p.startswith(("/admin", "/internal"))] == []


async def test_admin_endpoints_need_the_admin_token(private_client: AsyncClient) -> None:
    for secret in (None, "wrong", RU_SECRET):
        headers = {} if secret is None else admin(secret)
        for path in ("/admin/v1/disputes", "/admin/v1/import-runs"):
            answer = await private_client.get(path, headers=headers)
            assert answer.status_code == 401, (path, secret)
            assert answer.json()["error"]["code"] == "unauthorized"
        post = await private_client.post(
            f"/admin/v1/gtins/{GTIN}:resolve", json={"action": "reject"}, headers=headers
        )
        assert post.status_code == 401


async def test_admin_endpoints_are_rate_limited(migrated_db: str, clean_redis: None) -> None:
    settings = private_settings(rate_limit_ip_max=3)
    async with private_app_client(settings) as client:
        codes = [(await client.get("/admin/v1/disputes", headers=admin("x"))).status_code]
        codes += [(await client.get("/admin/v1/disputes", headers=admin("x"))).status_code]
        codes += [(await client.get("/admin/v1/disputes", headers=admin("x"))).status_code]
        codes += [(await client.get("/admin/v1/disputes", headers=admin("x"))).status_code]
    assert codes == [401, 401, 401, 429]


# --- resolving ------------------------------------------------------------------------------


async def test_lock_overrides_counts_and_the_public_lookup(
    client: AsyncClient,
    private_client: AsyncClient,
    seed: Seed,
    candidates: Candidates,
    engine: AsyncEngine,
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, a, 3)
    await candidates.put("ru", GTIN, b, 3)
    answer = await resolve(private_client, "lock", b)
    assert answer.status_code == 200
    assert answer.json() == {
        "gtin": GTIN,
        "status": "locked",
        "product_id": str(b),
        "decided_by": "admin",
        "reason_code": "admin_lock",
    }
    found = (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()
    assert found["status"] == "found"
    assert found["product"]["id"] == str(b)
    assert found["package"]["gtins"] == [GTIN]
    assert await audit(engine) == [("ops", "lock", GTIN, b)]


async def test_a_lock_is_not_changed_by_a_later_snapshot(
    client: AsyncClient, private_client: AsyncClient, seed: Seed
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await resolve(private_client, "lock", a)
    await put(private_client, [item(GTIN, b, 9)])
    found = (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()
    assert found["product"]["id"] == str(a)


async def test_reject_makes_the_number_unknown_and_survives_snapshots(
    client: AsyncClient, private_client: AsyncClient, seed: Seed, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 3)])
    assert (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()["status"] == "found"
    assert (await resolve(private_client, "reject")).status_code == 200
    assert (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()["status"] == (
        "unknown"
    )
    await put(private_client, [item(GTIN, a, 9)], generation=2)
    assert (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()["status"] == (
        "unknown"
    )
    assert await audit(engine) == [("ops", "reject", GTIN, None)]


async def test_promote_resolves_a_dispute_in_favour_of_one_product(
    client: AsyncClient, private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await put(private_client, [item(GTIN, a, 3), item(GTIN, b, 2)])
    assert (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()["status"] == (
        "disputed"
    )
    answer = await resolve(private_client, "promote", a)
    assert answer.json()["status"] == "promoted"
    found = (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()
    assert found["product"]["id"] == str(a)


async def test_promoting_another_product_than_the_official_one_is_refused(
    private_client: AsyncClient, seed: Seed, engine: AsyncEngine
) -> None:
    official = await seed.product("p-off", "Officialamol", packages=[("pack", [GTIN])])
    other = await seed.product("p-b", "Otheramol")
    answer = await resolve(private_client, "promote", other)
    assert (answer.status_code, answer.json()["error"]["code"]) == (409, "official_product_differs")
    assert (await resolve(private_client, "promote", official)).status_code == 200
    assert (await resolve(private_client, "lock", other)).status_code == 200  # the override
    assert [row[1] for row in await audit(engine)] == ["promote", "lock"]  # refusals not audited


async def test_resolve_validation(private_client: AsyncClient, seed: Seed) -> None:
    a = await seed.product("p-a", "Testamol")
    cases: list[tuple[str, str, uuid.UUID | None, int, str]] = [
        (GTIN, "promote", None, 422, "product_required"),
        (GTIN, "lock", None, 422, "product_required"),
        (GTIN, "reject", a, 422, "product_not_allowed"),
        (GTIN, "promote", uuid.uuid4(), 404, "unknown_product"),
        (RESTRICTED, "reject", None, 422, "invalid_gtin"),
        ("not-a-gtin", "reject", None, 422, "invalid_gtin"),
        ("04600000000016", "reject", None, 422, "invalid_gtin"),
    ]
    for gtin, action, product, status, code in cases:
        answer = await resolve(private_client, action, product, gtin=gtin)
        assert (answer.status_code, answer.json()["error"]["code"]) == (status, code), gtin
    bad_action = await private_client.post(
        f"/admin/v1/gtins/{GTIN}:resolve", json={"action": "delete"}, headers=admin()
    )
    assert bad_action.status_code == 422


async def test_a_withdrawn_product_cannot_be_chosen(
    private_client: AsyncClient, seed: Seed
) -> None:
    gone = await seed.product("p-gone", "Gonamol", withdrawn=True)
    assert (await resolve(private_client, "lock", gone)).status_code == 404


async def test_every_action_is_audited_with_the_token_label(
    private_client: AsyncClient, seed: Seed, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await resolve(private_client, "lock", a)
    await resolve(private_client, "reject", gtin=OTHER_GTIN, secret=ADMIN_SECOND_SECRET)
    await resolve(private_client, "promote", a, gtin=gtin14("0460701234569"))
    assert await audit(engine) == [
        ("ops", "lock", GTIN, a),
        ("ops-next", "reject", OTHER_GTIN, None),
        ("ops", "promote", gtin14("0460701234569"), a),
    ]


# --- reading ---------------------------------------------------------------------------------


async def test_disputes_are_listed_with_candidates_and_paged(
    private_client: AsyncClient, seed: Seed
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    third = gtin14("0460701234569")
    await put(
        private_client,
        [item(g, p, n) for g in (GTIN, OTHER_GTIN, third) for p, n in ((a, 3), (b, 2))],
    )
    first = (await private_client.get("/admin/v1/disputes?limit=2", headers=admin())).json()
    assert [d["gtin"] for d in first["items"]] == sorted([GTIN, OTHER_GTIN, third])[:2]
    assert first["next_after"] == first["items"][-1]["gtin"]
    top = first["items"][0]
    assert top["official_product_id"] is None
    assert [(c["name"], c["confirmations"]) for c in top["candidates"]] == [
        ("Testamol", 3),
        ("Otheramol", 2),
    ]
    rest = (
        await private_client.get(
            f"/admin/v1/disputes?limit=2&after={first['next_after']}", headers=admin()
        )
    ).json()
    assert [d["gtin"] for d in rest["items"]] == sorted([GTIN, OTHER_GTIN, third])[2:]
    assert rest["next_after"] is None


async def test_the_listing_limit_is_capped_and_validated(private_client: AsyncClient) -> None:
    assert (
        await private_client.get("/admin/v1/disputes?limit=0", headers=admin())
    ).status_code == 422
    assert (
        await private_client.get("/admin/v1/disputes?after=abc", headers=admin())
    ).status_code == 422
    big = await private_client.get("/admin/v1/disputes?limit=100000", headers=admin())
    assert big.status_code == 200


async def test_import_runs_are_listed_without_record_text(
    private_client: AsyncClient, seed: Seed
) -> None:
    await seed.product("p-a", "Testamol")  # the seed opens one succeeded run
    runs = (await private_client.get("/admin/v1/import-runs", headers=admin())).json()["items"]
    assert [r["status"] for r in runs] == ["succeeded"]
    assert set(runs[0]) == {
        "id",
        "source",
        "source_version",
        "status",
        "started_at",
        "finished_at",
        "counts",
        "error_code",
    }
