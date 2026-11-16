"""Search over ``search_entries`` (ADR 0012 section 5, docs/phase4-plan.md Search design).

Matching: the query is normalised by the database (``catalog.search_norm``, the function that also
generates ``norm`` and ``tsv``), so loader, index and search cannot disagree. An entry matches when
its ``tsv`` matches the query as a prefix on the last token, or when ``word_similarity`` passes the
configured threshold (typos). The typo path is a fallback, because a common word has thousands of
trigram neighbours and aggregating them is most of the cost of a query: the exact pass (``tsv``
only) runs first, and the typo pass (``tsv`` or trigram) replaces it only when the exact page has
fewer than ``limit`` active rows in the requested market (any market without one). A product is
found by its brand entries and through the entries of its substances (INN in any language), which
is how a Russian INN finds foreign products without any cross-market merge.

Order: withdrawn rows last, then own market first (D6), then score, then id (deterministic ties).
The order holds within the pass that answers; typo matches only fill a page that lacks active
own-market rows. There is no popularity signal and no analog list (D9). Neither the query nor the
ids are logged.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from uuid import UUID

from sqlalchemy import TextClause, text
from sqlalchemy.engine import RowMapping
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
# ``kind``, ``cap`` and the predicate are constants of this module; the exact statement carries no
# trigram predicate at all, so its plan never touches the trigram index.
_HITS = """
SELECT e.entity_id AS id,
       max(CASE WHEN e.tsv @@ CAST(:tsq AS tsquery)
                THEN ts_rank(e.tsv, CAST(:tsq AS tsquery)) ELSE 0 END
           + word_similarity(:qn, e.norm)) AS score
  FROM catalog.search_entries e
 WHERE e.entity_kind = '{kind}'
   AND {predicate}
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

# The labels are aggregated once for the ranked compositions (at most ``limit``), not per row: as
# a correlated ``ARRAY(SELECT ...)`` the planner re-ran the probe per result row, and on the full
# ESKLP that was most of a one-second search. MATERIALIZED keeps it a single pass.
_PRODUCT_SUMMARY = """
, labels AS MATERIALIZED (
    SELECT composition_id, array_agg(label ORDER BY label) AS substances
      FROM (
        SELECT ci.composition_id,
               CASE WHEN CAST(:lang AS text) = 'ru' THEN coalesce(s.name_ru, s.name_en)
                    ELSE coalesce(s.name_en, s.name_ru) END AS label
          FROM (SELECT DISTINCT p.composition_id
                  FROM ranked r
                  JOIN catalog.products p ON p.id = r.id) rc
          JOIN catalog.composition_ingredients ci ON ci.composition_id = rc.composition_id
          JOIN catalog.substances s ON s.id = ci.substance_id
      ) named
     GROUP BY composition_id
)
SELECT p.id, 'product' AS kind, p.brand_name AS name, p.market, p.country, p.manufacturer,
       CASE WHEN CAST(:lang AS text) = 'ru' THEN coalesce(c.form_name_ru, c.form_name_en)
            ELSE coalesce(c.form_name_en, c.form_name_ru) END AS form,
       coalesce(l.substances, CAST(ARRAY[] AS text[])) AS substances,
       p.withdrawn_at IS NOT NULL AS withdrawn
  FROM ranked r
  JOIN catalog.products p ON p.id = r.id
  LEFT JOIN catalog.compositions c ON c.id = p.composition_id
  LEFT JOIN labels l ON l.composition_id = p.composition_id
 ORDER BY r.pos
"""


_EXACT = "e.tsv @@ CAST(:tsq AS tsquery)"
_EXACT_OR_TYPO = "(e.tsv @@ CAST(:tsq AS tsquery) OR CAST(:qn AS text) <% e.norm)"


def _hits(kind: str, cap: str, *, typo: bool) -> str:
    return _HITS.format(kind=kind, cap=cap, predicate=_EXACT_OR_TYPO if typo else _EXACT)


def _text_products(*, typo: bool) -> TextClause:
    return text(
        _PRODUCT_RANKING.format(
            product_hits=_hits("product", "entry_cap", typo=typo),
            substance_hits=_hits("substance", "substance_cap", typo=typo),
            precision=_SCORE_PRECISION,
        )
        + _PRODUCT_SUMMARY
    )


def _text_substances(*, typo: bool) -> TextClause:
    return text(
        _SUBSTANCE_RANKING.format(
            substance_hits=_hits("substance", "entry_cap", typo=typo), precision=_SCORE_PRECISION
        )
    )


# Only module constants are interpolated; every request value is a bound parameter.
# (exact pass, typo pass) per kind.
TEXT_STATEMENTS: dict[str, tuple[TextClause, TextClause]] = {
    "product": (_text_products(typo=False), _text_products(typo=True)),
    "substance": (_text_substances(typo=False), _text_substances(typo=True)),
}
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


def _match_params(norm: str, tsquery: str) -> tuple[dict[str, object], bool] | None:
    """Bound parameters of the matching predicate, or None for a query too cheap to run.

    A one-letter prefix matches a large share of the table, so queries with fewer than two letters
    or digits are refused, the last token becomes a prefix only when it has two characters, and the
    typo pass needs at least one token of two characters (``a b`` would match by the trigrams of
    its space alone). Returns the parameters and whether the typo pass may run.
    """
    if len(_LETTER_OR_DIGIT.findall(norm)) < QUERY_MIN_LENGTH or not tsquery:
        return None
    lexemes = [m.replace("''", "'") for m in re.findall(r"'((?:[^']|'')*)'", tsquery)]
    last = _LAST_LEXEME.search(tsquery)
    prefix = last is not None and len(last.group(1)) >= QUERY_MIN_LENGTH
    params: dict[str, object] = {
        "qn": norm,
        # ``'testam':*``: the quoted lexeme is already escaped by PostgreSQL.
        "tsq": tsquery + (":*" if prefix else ""),
    }
    return params, any(len(token) >= QUERY_MIN_LENGTH for token in lexemes)


async def _search_text(
    session: AsyncSession, request: SearchRequest, settings: Settings
) -> list[SearchResult]:
    normalized = (await session.execute(_NORMALIZE, {"q": request.q})).one()
    match = _match_params(normalized.norm, normalized.tsquery)
    if match is None:
        return []
    match_params, typo_allowed = match
    limit = min(request.limit, settings.search_max_limit)
    params = {
        **match_params,
        "market": request.market,
        "lang": request.lang,
        "limit": limit,
        "entry_cap": settings.search_entry_cap,
        "substance_cap": settings.search_substance_cap,
    }
    exact, typo = TEXT_STATEMENTS["substance" if request.kind == "substance" else "product"]
    rows = (await session.execute(exact, params)).mappings().all()
    # Typos only fill a page without enough active own-market rows (module docstring).
    if typo_allowed and _useful_rows(rows, request.market) < limit:
        rows = (await session.execute(typo, params)).mappings().all()
    return [SearchResult.model_validate(dict(row)) for row in rows]


def _useful_rows(rows: Sequence[RowMapping], market: str | None) -> int:
    """Rows a typo match could not outrank: active and in the requested market (any without)."""
    return sum(
        1 for row in rows if not row["withdrawn"] and (market is None or row["market"] == market)
    )


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
