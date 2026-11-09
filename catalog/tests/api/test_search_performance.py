"""Search latency on a generated dataset (milestone 4.5: "p95 target").

The dataset is vacuumed, as a catalog is after an import run (fresh rows without hint bits make
every query several times slower). It is synthetic and only shaped like a real catalog: tens of
thousands of products that share compositions, a few thousand substances, three markets. The budget
is a third of the 300 ms statement timeout, measured through the whole ASGI stack with the database
on the same machine, so it guards against a plan regression (a missing index, an accidental
sequential scan), not against slow CI hardware.
"""

from __future__ import annotations

import statistics
import time

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.api.seed import DIGEST

PRODUCTS = 60_000
COMPOSITIONS = 20_000
SUBSTANCES = 3_000
P95_BUDGET_MS = 100.0
ROUNDS = 4

# (query, market, kind, whether it finds something)
QUERIES: list[tuple[str, str | None, str, bool]] = [
    ("ta", "ru", "product", True),
    ("mo", None, "product", True),
    ("tamori", "eu", "product", True),
    ("tamori 300", "ru", "product", True),
    ("sulfenor", "us", "product", True),  # substance name: goes through compositions
    ("tamorri", "ru", "product", True),  # typo
    ("ibupr", "ru", "product", False),
    ("ven", "us", "substance", True),
    ("1234567890123", None, "product", False),  # barcode-shaped
]

# Names are syllable products, so prefixes of every length hit many rows, like real brand names.
_GENERATE = """
WITH syl AS (SELECT ARRAY['ta','mo','ri','pa','len','xo','dra','ven','ci','sul','fe','nor'] AS a),
run AS (
    INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status, finished_at)
    VALUES (:run, 'openfda_ndc', :digest, 'succeeded', now()) RETURNING id
),
subs AS (
    INSERT INTO catalog.substances (id, source, source_key, market, name_en, last_run_id)
    SELECT gen_random_uuid(), 'openfda_ndc', 'S' || i, 'us',
           initcap(a[1 + i % 12] || a[1 + (i / 12) % 12] || a[1 + (i / 144) % 12] || 'ine'),
           (SELECT id FROM run)
      FROM syl, generate_series(1, :substances) AS i
    RETURNING id, name_en
),
numbered_subs AS (SELECT id, name_en, row_number() OVER (ORDER BY id) AS n FROM subs),
sub_entries AS (
    INSERT INTO catalog.search_entries (entity_kind, entity_id, market, lang, text)
    SELECT 'substance', id, 'us', 'en', name_en FROM numbered_subs
),
comps AS (
    INSERT INTO catalog.compositions
        (id, source, source_key, market, complete, identity_key, last_run_id)
    SELECT gen_random_uuid(), 'openfda_ndc', 'C' || i, 'us', false, md5('c' || i) || md5('d' || i),
           (SELECT id FROM run)
      FROM generate_series(1, :compositions) AS i
    RETURNING id, source_key
),
numbered_comps AS (
    SELECT id, substr(source_key, 2)::int AS n FROM comps
),
ingredients AS (
    INSERT INTO catalog.composition_ingredients (composition_id, substance_id)
    SELECT c.id, s.id FROM numbered_comps c JOIN numbered_subs s ON s.n = 1 + c.n % :substances
)
INSERT INTO catalog.products
    (id, source, source_key, market, brand_name, country, composition_id, last_run_id)
SELECT gen_random_uuid(), 'openfda_ndc', 'P' || i, (ARRAY['ru', 'us', 'eu'])[1 + i % 3],
       initcap(a[1 + i % 12] || a[1 + (i / 12) % 12] || a[1 + (i / 144) % 12]
               || a[1 + (i / 1728) % 12]) || ' ' || (100 * (1 + i % 7)),
       'US', c.id, (SELECT id FROM run)
  FROM syl, generate_series(1, :products) AS i
  JOIN numbered_comps c ON c.n = 1 + i % :compositions
"""

_PRODUCT_ENTRIES = """
INSERT INTO catalog.search_entries (entity_kind, entity_id, market, lang, text)
SELECT 'product', id, market, 'en', brand_name FROM catalog.products
ON CONFLICT DO NOTHING
"""


async def _generate(engine: AsyncEngine) -> None:
    import uuid

    async with engine.begin() as conn:
        await conn.execute(
            text(_GENERATE),
            {
                "run": uuid.uuid4(),
                "digest": DIGEST,
                "substances": SUBSTANCES,
                "compositions": COMPOSITIONS,
                "products": PRODUCTS,
            },
        )
        await conn.execute(text(_PRODUCT_ENTRIES))
    async with engine.connect() as conn:
        raw = await conn.execution_options(isolation_level="AUTOCOMMIT")
        for table in (
            "search_entries",
            "products",
            "compositions",
            "composition_ingredients",
            "substances",
        ):
            await raw.execute(text(f"VACUUM (ANALYZE) catalog.{table}"))


async def test_p95_latency_on_a_generated_dataset(
    client: AsyncClient, engine: AsyncEngine, seed: object
) -> None:
    del seed  # requested for its clean-up of the content tables
    await _generate(engine)
    samples: list[float] = []
    for _ in range(ROUNDS):
        for q, market, kind, hits in QUERIES:
            body: dict[str, object] = {"q": q, "lang": "en", "kind": kind}
            if market:
                body["market"] = market
            started = time.perf_counter()
            response = await client.post("/v1/search", json=body)
            samples.append((time.perf_counter() - started) * 1000)
            assert response.status_code == 200, q
            assert bool(response.json()["results"]) == hits, q
    p95 = statistics.quantiles(samples, n=20)[-1]
    assert p95 < P95_BUDGET_MS, f"p95 {p95:.0f} ms over {len(samples)} requests"
