"""Deciding which product a GTIN belongs to, and the admin's say in it (ADR 0014 sections 4, 5).

``redecide_many`` reads the facts of a set of GTINs in a few bulk queries, asks the pure
``decide`` (``catalog.domain.consensus``) and stores what changed. ``resolve`` is the admin's
override. Both keep two invariants the public lookup (``services/gtins.py``) relies on:

* a ``promoted`` or ``locked`` decision has a live **consensus** ``gtins`` row for its product
  (unless an official source row already carries the number), so the ordinary row lookup and the
  product card list the package;
* a ``disputed``, ``rejected`` or ``pending`` number has **no** live consensus row.

**One global lock.** Every writer (ingest commit, admin resolve, expiry, importer hook) takes
``lock_consensus`` once per transaction, so two writers never deadlock on each other's GTINs and
the lock table never grows with the size of a snapshot (a per-GTIN lock for 10k GTINs would
exhaust ``max_locks_per_transaction``). ``redecide_many`` requires the lock to be held.

Counts of a region count only while its last committed snapshot is younger than
``CATALOG_INGEST_MAX_AGE_HOURS``: a region that stopped reporting (or was switched off) fades
out instead of staying in the catalog forever.

Nothing here knows a person, a region's users or a device: the inputs are counts.
"""

from __future__ import annotations

import hashlib
import uuid
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Literal, get_args

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.config import Settings
from catalog.domain.consensus import (
    REASON_ADMIN_LOCK,
    REASON_ADMIN_REJECT,
    CurrentDecision,
    DecidedBy,
    Decision,
    Status,
    Thresholds,
    decide,
)
from catalog.domain.identity import CATALOG_NAMESPACE, consensus_package_id

AdminAction = Literal["promote", "reject", "lock"]
REASON_ADMIN_PROMOTE = "admin_promote"
CONSENSUS_SOURCE = "consensus"
# The synthetic run that carries every consensus package; the migration (c0005) creates the row.
CONSENSUS_RUN_ID = uuid.uuid5(CATALOG_NAMESPACE, "consensus:run")
CONSENSUS_RUN_DIGEST = hashlib.sha256(b"consensus").hexdigest()
LOCK_KEY = "gtin_link:all"

_STATUSES: dict[str, Status] = {s: s for s in get_args(Status)}


class DecisionError(Exception):
    """An admin action is not possible; ``code`` is a stable error code, never input text."""

    def __init__(self, code: str, status_code: int = 409) -> None:
        super().__init__(code)
        self.code = code
        self.status_code = status_code


@dataclass(frozen=True)
class Rules:
    thresholds: Thresholds
    max_age_hours: int
    audit_retention_days: int = 730

    @classmethod
    def from_settings(cls, settings: Settings) -> Rules:
        return cls(
            Thresholds(settings.consensus_min_confirmations, settings.consensus_dispute_min),
            settings.ingest_max_age_hours,
            settings.audit_retention_days,
        )


_LOCK = text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))")
_CURRENT_MANY = text(
    "SELECT gtin, status, product_id, decided_by, reason_code FROM catalog.gtin_link_decisions "
    "WHERE gtin = ANY(:gtins)"
)
_OFFICIAL_MANY = text(
    """
SELECT DISTINCT ON (g.gtin) g.gtin, pk.product_id
  FROM catalog.gtins g
  JOIN catalog.packages pk ON pk.id = g.package_id
  JOIN catalog.products p ON p.id = pk.product_id
 WHERE g.gtin = ANY(:gtins) AND g.origin = 'source' AND g.withdrawn_at IS NULL
   AND pk.withdrawn_at IS NULL AND p.withdrawn_at IS NULL
 ORDER BY g.gtin, g.source, pk.id
"""
)
_COUNTS_MANY = text(
    """
SELECT c.gtin, c.product_id, sum(c.confirmations)::int AS total
  FROM catalog.gtin_link_candidates c
  JOIN catalog.gtin_ingest_state s
    ON s.region = c.region AND s.committed_at >= now() - make_interval(hours => :hours)
  JOIN catalog.products p ON p.id = c.product_id AND p.withdrawn_at IS NULL
 WHERE c.gtin = ANY(:gtins)
 GROUP BY c.gtin, c.product_id
"""
)
_UPSERT = text(
    """
INSERT INTO catalog.gtin_link_decisions (gtin, status, product_id, decided_by, decided_at,
                                         reason_code)
VALUES (:gtin, :status, :product, :by, now(), :reason)
ON CONFLICT (gtin) DO UPDATE
   SET status = :status, product_id = :product, decided_by = :by, decided_at = now(),
       reason_code = :reason
"""
)
_LIVE_PRODUCT = text("SELECT 1 FROM catalog.products WHERE id = :id AND withdrawn_at IS NULL")
_ENSURE_PACKAGE = text(
    "INSERT INTO catalog.packages (id, product_id, source, source_key, last_run_id) "
    "VALUES (:pk, :product, :source, :key, :run) "
    "ON CONFLICT (id) DO UPDATE SET withdrawn_at = NULL"
)
_ENSURE_GTIN = text(
    "INSERT INTO catalog.gtins (gtin, source, package_id, origin, last_run_id) "
    "VALUES (:gtin, :source, :pk, 'consensus', :run) "
    "ON CONFLICT (gtin, source) DO UPDATE "
    "SET package_id = :pk, origin = 'consensus', withdrawn_at = NULL"
)
# A package of an earlier link of a number must not stay on the other product's card.
_WITHDRAW_OTHER_PACKAGES = text(
    "UPDATE catalog.packages SET withdrawn_at = now() WHERE source = :source "
    "AND split_part(source_key, ':', 1) = ANY(:gtins) AND id <> ALL(:keep) "
    "AND withdrawn_at IS NULL"
)
_WITHDRAW_GTINS = text(
    "UPDATE catalog.gtins SET withdrawn_at = now() WHERE source = :source "
    "AND gtin = ANY(:gtins) AND withdrawn_at IS NULL"
)
_WITHDRAW_PACKAGES = text(
    "UPDATE catalog.packages SET withdrawn_at = now() WHERE source = :source "
    "AND split_part(source_key, ':', 1) = ANY(:gtins) AND withdrawn_at IS NULL"
)
_AUDIT = text(
    "INSERT INTO catalog.admin_audit (admin_name, action, gtin, product_id, previous_status, "
    "previous_product_id) VALUES (:name, :action, :gtin, :product, :prev_status, :prev_product)"
)
_ALL_DECIDED_OR_COUNTED = text(
    "SELECT gtin FROM catalog.gtin_link_decisions UNION "
    "SELECT gtin FROM catalog.gtin_link_candidates ORDER BY gtin"
)


@dataclass(frozen=True)
class Stored:
    status: Status
    product_id: uuid.UUID | None
    decided_by: DecidedBy
    reason_code: str | None

    def current(self) -> CurrentDecision:
        return CurrentDecision(self.status, self.product_id, self.decided_by)


async def lock_consensus(session: AsyncSession) -> None:
    """The one lock of every consensus writer; held until the transaction ends."""
    await session.execute(_LOCK, {"key": LOCK_KEY})


async def stored_many(session: AsyncSession, gtins: Sequence[str]) -> dict[str, Stored]:
    rows = await session.execute(_CURRENT_MANY, {"gtins": list(gtins)})
    return {
        r.gtin: Stored(
            _STATUSES[r.status],
            r.product_id,
            "admin" if r.decided_by == "admin" else "auto",
            r.reason_code,
        )
        for r in rows
    }


async def _official_many(session: AsyncSession, gtins: Sequence[str]) -> dict[str, uuid.UUID]:
    rows = await session.execute(_OFFICIAL_MANY, {"gtins": list(gtins)})
    return {r.gtin: r.product_id for r in rows}


async def _counts_many(
    session: AsyncSession, gtins: Sequence[str], max_age_hours: int
) -> dict[str, dict[uuid.UUID, int]]:
    rows = await session.execute(_COUNTS_MANY, {"gtins": list(gtins), "hours": max_age_hours})
    counts: dict[str, dict[uuid.UUID, int]] = {}
    for r in rows:
        counts.setdefault(r.gtin, {})[r.product_id] = r.total
    return counts


async def _ensure_rows(session: AsyncSession, links: dict[str, uuid.UUID]) -> None:
    if not links:
        return
    common = {"source": CONSENSUS_SOURCE, "run": CONSENSUS_RUN_ID}
    rows = [
        {
            **common,
            "gtin": gtin,
            "product": product,
            "pk": consensus_package_id(gtin, product),
            "key": f"{gtin}:{product}",
        }
        for gtin, product in links.items()
    ]
    await session.execute(_ENSURE_PACKAGE, rows)
    await session.execute(_ENSURE_GTIN, rows)
    await session.execute(
        _WITHDRAW_OTHER_PACKAGES,
        {"source": CONSENSUS_SOURCE, "gtins": list(links), "keep": [r["pk"] for r in rows]},
    )


async def _withdraw_rows(session: AsyncSession, gtins: list[str]) -> None:
    if gtins:
        params = {"source": CONSENSUS_SOURCE, "gtins": gtins}
        await session.execute(_WITHDRAW_GTINS, params)
        await session.execute(_WITHDRAW_PACKAGES, params)


async def _sync_consensus_rows(
    session: AsyncSession, decided: dict[str, Decision], official: dict[str, uuid.UUID]
) -> None:
    links: dict[str, uuid.UUID] = {}
    withdraw: list[str] = []
    for gtin, decision in decided.items():
        carries_a_link = decision.status in ("promoted", "locked")
        product = decision.product_id
        if carries_a_link and product is not None and product != official.get(gtin):
            links[gtin] = product
        else:
            withdraw.append(gtin)
    await _ensure_rows(session, links)
    await _withdraw_rows(session, withdraw)


async def _store(session: AsyncSession, decided: dict[str, Decision]) -> None:
    if decided:
        await session.execute(
            _UPSERT,
            [
                {
                    "gtin": gtin,
                    "status": d.status,
                    "product": d.product_id,
                    "by": d.decided_by,
                    "reason": d.reason_code,
                }
                for gtin, d in decided.items()
            ],
        )


def _differs(known: Stored | None, decision: Decision) -> bool:
    return known is None or (known.status, known.product_id, known.decided_by) != (
        decision.status,
        decision.product_id,
        decision.decided_by,
    )


async def redecide_many(session: AsyncSession, gtins: Sequence[str], rules: Rules) -> int:
    """Re-evaluate ``gtins`` inside the caller's transaction (the global lock must be held).

    Returns how many decisions were written. A GTIN nobody confirmed and that has no decision is
    left alone. The consensus rows follow the decision of every evaluated GTIN, because an
    official row can appear or vanish without the decision changing.
    """
    unique = sorted(set(gtins))
    if not unique:
        return 0
    stored = await stored_many(session, unique)
    counts = await _counts_many(session, unique, rules.max_age_hours)
    official = await _official_many(session, unique)
    decided: dict[str, Decision] = {}
    changed: dict[str, Decision] = {}
    for gtin in unique:
        known = stored.get(gtin)
        if known is None and gtin not in counts:
            continue
        current = None if known is None else known.current()
        decision = decide(official.get(gtin), counts.get(gtin, {}), current, rules.thresholds)
        decided[gtin] = decision
        if _differs(known, decision):
            changed[gtin] = decision
    await _store(session, changed)
    await _sync_consensus_rows(session, decided, official)
    return len(changed)


async def redecide(session: AsyncSession, gtin: str, rules: Rules) -> Decision | None:
    """One GTIN under the global lock; ``None`` when nobody confirmed it."""
    await lock_consensus(session)
    await redecide_many(session, [gtin], rules)
    known = (await stored_many(session, [gtin])).get(gtin)
    if known is None:
        return None
    return Decision(known.status, known.product_id, known.decided_by, known.reason_code or "")


async def redecide_everything(session: AsyncSession, rules: Rules) -> int:
    """Every GTIN that has a decision or a candidate (maintenance, after an import)."""
    await lock_consensus(session)
    gtins = [row.gtin for row in await session.execute(_ALL_DECIDED_OR_COUNTED)]
    return await redecide_many(session, gtins, rules)


def _admin_decision(action: AdminAction, product_id: uuid.UUID | None) -> Decision:
    if action == "promote":
        return Decision("promoted", product_id, "admin", REASON_ADMIN_PROMOTE)
    if action == "lock":
        return Decision("locked", product_id, "admin", REASON_ADMIN_LOCK)
    return Decision("rejected", product_id, "admin", REASON_ADMIN_REJECT)


async def resolve(
    session: AsyncSession,
    gtin: str,
    action: AdminAction,
    product_id: uuid.UUID | None,
    admin_name: str,
) -> Decision:
    """An admin's decision, audited (with the decision it replaces) in the same transaction.

    A later automatic evaluation attributes a ``promote`` to ``auto`` / ``sticky_promotion``
    again; the audit rows keep the history (ADR 0014 section 5).
    """
    needs_product = action in ("promote", "lock")
    if needs_product != (product_id is not None):
        raise DecisionError("product_required" if needs_product else "product_not_allowed", 422)
    await lock_consensus(session)
    if product_id is not None:
        live = (await session.execute(_LIVE_PRODUCT, {"id": product_id})).scalar_one_or_none()
        if live is None:
            raise DecisionError("unknown_product", 404)
    official = await _official_many(session, [gtin])
    if action == "promote" and gtin in official and official[gtin] != product_id:
        # Overriding an official row is a lock, not a promotion.
        raise DecisionError("official_product_differs")
    previous = (await stored_many(session, [gtin])).get(gtin)
    decision = _admin_decision(action, product_id)
    await _store(session, {gtin: decision})
    await _sync_consensus_rows(session, {gtin: decision}, official)
    await session.execute(
        _AUDIT,
        {
            "name": admin_name,
            "action": action,
            "gtin": gtin,
            "product": product_id,
            "prev_status": None if previous is None else previous.status,
            "prev_product": None if previous is None else previous.product_id,
        },
    )
    return decision
