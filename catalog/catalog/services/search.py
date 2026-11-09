"""Search over ``search_entries`` (ADR 0012 section 5, docs/phase4-plan.md Search design).

Matching: the query is normalised by the database (``catalog.search_norm``, the function that also
generates ``norm`` and ``tsv``), so loader, index and search cannot disagree. An entry matches when
its ``tsv`` matches the query as a prefix on the last token, or when ``word_similarity`` passes the
configured threshold (typos). A product is found by its brand entries and through the entries of
its substances (INN in any language), which is how a Russian INN finds foreign products without
any cross-market merge.

Order: withdrawn rows last, then own market first (D6), then score, then id (deterministic ties).
There is no popularity signal and no analog list (D9). Neither the query nor the ids are logged.
"""

from __future__ import annotations

import re
from uuid import UUID

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.config import Settings
from catalog.domain.gtin import GtinError, normalize
from catalog.schemas.search import (
    QUERY_MIN_LENGTH,
    SearchRequest,
    SearchResponse,
    SearchResult,
)
from catalog.services.gtins import find_product_by_gtin

# A scan or a typed barcode: 8, 12, 13 or 14 digits (docs/spec/gtin.md section 2).
_DIGITS = re.compile(r"[0-9]{8}|[0-9]{12,14}")
_SCORE_PRECISION = 3
_LETTER_OR_DIGIT = re.compile(r"[^\W_]")
_LAST_LEXEME = re.compile(r"'((?:[^']|'')*)'$")

_NORMALIZE = text(
    "SELECT catalog.search_norm(:q) AS norm, "
    "plainto_tsquery('simple', catalog.search_norm(:q))::text AS tsquery"
)

# Entries of one kind that match; one score per entity (its best entry). Own market first, so the
# cap never cuts off the market the person is in. The cap cannot see ``withdrawn_at`` (entries do
# not carry it): with more than ``cap`` matching entities, withdrawn ones may use cap slots that
# active ones would have taken; the final order still puts withdrawn rows last.
# ``kind`` and ``cap`` are constants of this module; ``:trgm`` switches the typo path off.
_HITS = """
SELECT e.entity_id AS id,
       max(CASE WHEN e.tsv @@ CAST(:tsq AS tsquery)
                THEN ts_rank(e.tsv, CAST(:tsq AS tsquery)) ELSE 0 END
           + word_similarity(:qn, e.norm)) AS score
  FROM catalog.search_entries e
 WHERE e.entity_kind = '{kind}'
   AND (e.tsv @@ CAST(:tsq AS tsquery) OR (:trgm AND CAST(:qn AS text) <% e.norm))
 GROUP BY e.entity_id
 ORDER BY (min(e.market) = CAST(:market AS text)) DESC, 2 DESC, e.entity_id
 LIMIT :{cap}
"""

# Per substance only the best ``limit`` products can reach the final page: within one substance
# the final order is (withdrawn, own market, id) because the score is shared.
_PRODUCT_RANKING = """
WITH product_hits AS ({product_hits}),
substance_hits AS ({substance_hits}),
via_substance AS (
    SELECT p.id, h.score
      FROM substance_hits h
     CROSS JOIN LATERAL (
        SELECT p.id
          FROM catalog.composition_ingredients ci
          JOIN catalog.products p ON p.composition_id = ci.composition_id
         WHERE ci.substance_id = h.id
         ORDER BY (p.withdrawn_at IS NOT NULL), (p.market = CAST(:market AS text)) DESC, p.id
         LIMIT :limit
     ) p
),
best AS (
    SELECT id, max(score) AS score
      FROM (SELECT id, score FROM product_hits UNION ALL SELECT id, score FROM via_substance) u
     GROUP BY id
),
ranked AS (
    SELECT p.id,
           row_number() OVER (
               ORDER BY (p.withdrawn_at IS NOT NULL),
                        (p.market = CAST(:market AS text)) DESC,
                        round(CAST(b.score AS numeric), {precision}) DESC,
                        p.id
           ) AS pos
      FROM best b
      JOIN catalog.products p ON p.id = b.id
     ORDER BY pos
     LIMIT :limit
)
"""

_SUBSTANCE_RANKING = """
WITH substance_hits AS ({substance_hits}),
ranked AS (
    SELECT s.id,
           row_number() OVER (
               ORDER BY (s.withdrawn_at IS NOT NULL),
                        (s.market = CAST(:market AS text)) DESC,
                        round(CAST(h.score AS numeric), {precision}) DESC,
                        s.id
           ) AS pos
      FROM substance_hits h
      JOIN catalog.substances s ON s.id = h.id
     ORDER BY pos
     LIMIT :limit
)
SELECT s.id, 'substance' AS kind,
       CASE WHEN CAST(:lang AS text) = 'ru' THEN coalesce(s.name_ru, s.name_en)
            ELSE coalesce(s.name_en, s.name_ru) END AS name,
       s.market, CAST(NULL AS text) AS country, CAST(NULL AS text) AS manufacturer,
       CAST(NULL AS text) AS form, CAST(ARRAY[] AS text[]) AS substances,
       s.withdrawn_at IS NOT NULL AS withdrawn
  FROM ranked r
  JOIN catalog.substances s ON s.id = r.id
 ORDER BY r.pos
"""

_PRODUCT_SUMMARY = """
SELECT p.id, 'product' AS kind, p.brand_name AS name, p.market, p.country, p.manufacturer,
       CASE WHEN CAST(:lang AS text) = 'ru' THEN coalesce(c.form_name_ru, c.form_name_en)
            ELSE coalesce(c.form_name_en, c.form_name_ru) END AS form,
       ARRAY(
           SELECT CASE WHEN CAST(:lang AS text) = 'ru' THEN coalesce(s.name_ru, s.name_en)
                       ELSE coalesce(s.name_en, s.name_ru) END AS label
             FROM catalog.composition_ingredients ci
             JOIN catalog.substances s ON s.id = ci.substance_id
            WHERE ci.composition_id = p.composition_id
            ORDER BY label
       ) AS substances,
       p.withdrawn_at IS NOT NULL AS withdrawn
  FROM ranked r
  JOIN catalog.products p ON p.id = r.id
  LEFT JOIN catalog.compositions c ON c.id = p.composition_id
 ORDER BY r.pos
"""


def _hits(kind: str, cap: str) -> str:
    return _HITS.format(kind=kind, cap=cap)


# Only module constants are interpolated; every request value is a bound parameter.
_TEXT_PRODUCTS = text(
    _PRODUCT_RANKING.format(
        product_hits=_hits("product", "entry_cap"),
        substance_hits=_hits("substance", "substance_cap"),
        precision=_SCORE_PRECISION,
    )
    + _PRODUCT_SUMMARY
)
_TEXT_SUBSTANCES = text(
    _SUBSTANCE_RANKING.format(
        substance_hits=_hits("substance", "entry_cap"), precision=_SCORE_PRECISION
    )
)
_BY_IDS = text(
    "WITH ranked AS (SELECT id, pos FROM unnest(CAST(:ids AS uuid[])) "  # noqa: S608
    "WITH ORDINALITY AS t(id, pos)) " + _PRODUCT_SUMMARY
)


def gtin_digits(q: str) -> str | None:
    """The digits of ``q`` when it is a barcode-shaped query, else None."""
    compact = q.replace(" ", "").replace("-", "")
    return compact if _DIGITS.fullmatch(compact) else None


async def product_summaries(
    session: AsyncSession, ids: list[UUID], lang: str
) -> list[SearchResult]:
    if not ids:
        return []
    rows = (await session.execute(_BY_IDS, {"ids": ids, "lang": lang})).mappings().all()
    return [SearchResult.model_validate(dict(row)) for row in rows]


async def _search_gtin(session: AsyncSession, digits: str, lang: str) -> list[SearchResult]:
    try:
        gtin = normalize(digits)
    except GtinError:
        return []
    if gtin.classification == "restricted":
        return []  # private numbers are never looked up, not even to answer "unknown"
    product_id = await find_product_by_gtin(session, gtin.gtin14)
    return await product_summaries(session, [product_id] if product_id else [], lang)


def _match_params(norm: str, tsquery: str) -> dict[str, object] | None:
    """Bound parameters of the matching predicate, or None for a query too cheap to run.

    A one-letter prefix matches a large share of the table, so queries with fewer than two letters
    or digits are refused, the last token becomes a prefix only when it has two characters, and the
    typo path needs at least one token of two characters (``a b`` would match by the trigrams of
    its space alone).
    """
    if len(_LETTER_OR_DIGIT.findall(norm)) < QUERY_MIN_LENGTH or not tsquery:
        return None
    lexemes = [m.replace("''", "'") for m in re.findall(r"'((?:[^']|'')*)'", tsquery)]
    last = _LAST_LEXEME.search(tsquery)
    prefix = last is not None and len(last.group(1)) >= QUERY_MIN_LENGTH
    return {
        "qn": norm,
        # ``'testam':*``: the quoted lexeme is already escaped by PostgreSQL.
        "tsq": tsquery + (":*" if prefix else ""),
        "trgm": any(len(token) >= QUERY_MIN_LENGTH for token in lexemes),
    }


async def _search_text(
    session: AsyncSession, request: SearchRequest, settings: Settings
) -> list[SearchResult]:
    normalized = (await session.execute(_NORMALIZE, {"q": request.q})).one()
    match = _match_params(normalized.norm, normalized.tsquery)
    if match is None:
        return []
    params = {
        **match,
        "market": request.market,
        "lang": request.lang,
        "limit": min(request.limit, settings.search_max_limit),
        "entry_cap": settings.search_entry_cap,
        "substance_cap": settings.search_substance_cap,
    }
    statement = _TEXT_SUBSTANCES if request.kind == "substance" else _TEXT_PRODUCTS
    rows = (await session.execute(statement, params)).mappings().all()
    return [SearchResult.model_validate(dict(row)) for row in rows]


async def search(
    session: AsyncSession, request: SearchRequest, settings: Settings
) -> SearchResponse:
    digits = gtin_digits(request.q)
    if digits is None:
        return SearchResponse(mode="text", results=await _search_text(session, request, settings))
    results = (
        [] if request.kind == "substance" else await _search_gtin(session, digits, request.lang)
    )
    return SearchResponse(mode="gtin", results=results)
