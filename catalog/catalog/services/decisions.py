"""Deciding which product a GTIN belongs to, and the admin's say in it (ADR 0014 sections 4, 5).

``redecide`` reads the facts of one GTIN under a per-GTIN advisory lock, asks the pure
``decide`` (``catalog.domain.consensus``) and stores the result. ``resolve`` is the admin's
override. Both keep two invariants the public lookup (``services/gtins.py``) relies on:

* a ``promoted`` or ``locked`` decision has a live **consensus** ``gtins`` row for its product
  (unless an official source row already carries the number), so the ordinary row lookup and the
  product card list the package;
* a ``disputed``, ``rejected`` or ``pending`` number has **no** live consensus row.

Nothing here knows a person, a region's users or a device: the inputs are counts.
"""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from typing import Literal

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.domain.consensus import (
    REASON_ADMIN_LOCK,
    REASON_ADMIN_REJECT,
    CurrentDecision,
    Decision,
    Thresholds,
    decide,
)
from catalog.domain.identity import CATALOG_NAMESPACE, consensus_package_id

AdminAction = Literal["promote", "reject", "lock"]
REASON_ADMIN_PROMOTE = "admin_promote"
CONSENSUS_SOURCE = "consensus"
# One synthetic run carries every consensus package (``packages.last_run_id`` is mandatory).
_RUN_ID = uuid.uuid5(CATALOG_NAMESPACE, "consensus:run")
_RUN_DIGEST = hashlib.sha256(b"consensus").hexdigest()


class DecisionError(Exception):
    """An admin action is not possible; ``code`` is a stable error code, never input text."""

    def __init__(self, code: str, status_code: int = 409) -> None:
        super().__init__(code)
        self.code = code
        self.status_code = status_code


_LOCK = text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))")
_CURRENT = text(
    "SELECT status, product_id, decided_by FROM catalog.gtin_link_decisions WHERE gtin = :gtin"
)
_OFFICIAL = text(
    """
SELECT pk.product_id
  FROM catalog.gtins g
  JOIN catalog.packages pk ON pk.id = g.package_id
  JOIN catalog.products p ON p.id = pk.product_id
 WHERE g.gtin = :gtin AND g.origin = 'source' AND g.withdrawn_at IS NULL
   AND pk.withdrawn_at IS NULL AND p.withdrawn_at IS NULL
 ORDER BY g.source, pk.id
 LIMIT 1
"""
)
_COUNTS = text(
    """
SELECT c.product_id, sum(c.confirmations)::int AS total
  FROM catalog.gtin_link_candidates c
  JOIN catalog.products p ON p.id = c.product_id AND p.withdrawn_at IS NULL
 WHERE c.gtin = :gtin
 GROUP BY c.product_id
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


@dataclass(frozen=True)
class Stored:
    status: str
    product_id: uuid.UUID | None
    decided_by: str


async def _lock(session: AsyncSession, gtin: str) -> None:
    await session.execute(_LOCK, {"key": f"gtin_link:{gtin}"})


async def _current(session: AsyncSession, gtin: str) -> Stored | None:
    row = (await session.execute(_CURRENT, {"gtin": gtin})).one_or_none()
    return None if row is None else Stored(row.status, row.product_id, row.decided_by)


async def _official(session: AsyncSession, gtin: str) -> uuid.UUID | None:
    return (await session.execute(_OFFICIAL, {"gtin": gtin})).scalar_one_or_none()


async def _counts(session: AsyncSession, gtin: str) -> dict[uuid.UUID, int]:
    rows = (await session.execute(_COUNTS, {"gtin": gtin})).all()
    return {row.product_id: row.total for row in rows}


async def _store(session: AsyncSession, gtin: str, decision: Decision) -> None:
    await session.execute(
        _UPSERT,
        {
            "gtin": gtin,
            "status": decision.status,
            "product": decision.product_id,
            "by": decision.decided_by,
            "reason": decision.reason_code,
        },
    )


async def _ensure_consensus_row(session: AsyncSession, gtin: str, product_id: uuid.UUID) -> None:
    package_id = consensus_package_id(gtin, product_id)
    params = {
        "run": _RUN_ID,
        "sha": _RUN_DIGEST,
        "pk": package_id,
        "product": product_id,
        "gtin": gtin,
        "source": CONSENSUS_SOURCE,
        "key": f"{gtin}:{product_id}",
    }
    await session.execute(
        text(
            "INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status, finished_at) "
            "VALUES (:run, :source, :sha, 'succeeded', now()) ON CONFLICT (id) DO NOTHING"
        ),
        params,
    )
    await session.execute(
        text(
            "INSERT INTO catalog.packages (id, product_id, source, source_key, last_run_id) "
            "VALUES (:pk, :product, :source, :key, :run) "
            "ON CONFLICT (id) DO UPDATE SET withdrawn_at = NULL"
        ),
        params,
    )
    await session.execute(
        text(
            "INSERT INTO catalog.gtins (gtin, source, package_id, origin, last_run_id) "
            "VALUES (:gtin, :source, :pk, 'consensus', :run) "
            "ON CONFLICT (gtin, source) DO UPDATE "
            "SET package_id = :pk, origin = 'consensus', withdrawn_at = NULL"
        ),
        params,
    )
    # A package of an earlier link of this number must not stay on the other product's card.
    await session.execute(
        text(
            "UPDATE catalog.packages SET withdrawn_at = now() WHERE source = :source "
            "AND split_part(source_key, ':', 1) = :gtin AND id <> :pk AND withdrawn_at IS NULL"
        ),
        params,
    )


async def _withdraw_consensus_row(session: AsyncSession, gtin: str) -> None:
    params = {"gtin": gtin, "source": CONSENSUS_SOURCE}
    await session.execute(
        text(
            "UPDATE catalog.gtins SET withdrawn_at = now() WHERE gtin = :gtin "
            "AND source = :source AND withdrawn_at IS NULL"
        ),
        params,
    )
    await session.execute(
        text(
            "UPDATE catalog.packages SET withdrawn_at = now() WHERE source = :source "
            "AND split_part(source_key, ':', 1) = :gtin AND withdrawn_at IS NULL"
        ),
        params,
    )


async def _sync_consensus_row(
    session: AsyncSession, gtin: str, decision: Decision, official: uuid.UUID | None
) -> None:
    carries_a_link = decision.status in ("promoted", "locked") and decision.product_id is not None
    if carries_a_link and decision.product_id != official:
        assert decision.product_id is not None  # noqa: S101
        await _ensure_consensus_row(session, gtin, decision.product_id)
    else:
        await _withdraw_consensus_row(session, gtin)


async def redecide(session: AsyncSession, gtin: str, thresholds: Thresholds) -> Decision | None:
    """Re-evaluate one GTIN inside the caller's transaction; ``None`` when nobody confirmed it."""
    await _lock(session, gtin)
    stored = await _current(session, gtin)
    counts = await _counts(session, gtin)
    if stored is None and not counts:
        return None
    official = await _official(session, gtin)
    current = (
        None
        if stored is None
        else CurrentDecision(
            stored.status,  # type: ignore[arg-type]
            stored.product_id,
            stored.decided_by,  # type: ignore[arg-type]
        )
    )
    decision = decide(official, counts, current, thresholds)
    if stored is None or (stored.status, stored.product_id, stored.decided_by) != (
        decision.status,
        decision.product_id,
        decision.decided_by,
    ):
        await _store(session, gtin, decision)
    await _sync_consensus_row(session, gtin, decision, official)
    return decision


async def resolve(
    session: AsyncSession,
    gtin: str,
    action: AdminAction,
    product_id: uuid.UUID | None,
    admin_name: str,
) -> Decision:
    """An admin's decision, audited in the same transaction (ADR 0014 section 5)."""
    needs_product = action in ("promote", "lock")
    if needs_product != (product_id is not None):
        raise DecisionError("product_required" if needs_product else "product_not_allowed", 422)
    await _lock(session, gtin)
    if product_id is not None:
        live = (await session.execute(_LIVE_PRODUCT, {"id": product_id})).scalar_one_or_none()
        if live is None:
            raise DecisionError("unknown_product", 404)
    official = await _official(session, gtin)
    if action == "promote" and official is not None and official != product_id:
        # Overriding an official row is a lock, not a promotion.
        raise DecisionError("official_product_differs")
    decision = Decision(
        {"promote": "promoted", "reject": "rejected", "lock": "locked"}[action],  # type: ignore[arg-type]
        product_id,
        "admin",
        {
            "promote": REASON_ADMIN_PROMOTE,
            "reject": REASON_ADMIN_REJECT,
            "lock": REASON_ADMIN_LOCK,
        }[action],
    )
    await _store(session, gtin, decision)
    await _sync_consensus_row(session, gtin, decision, official)
    await session.execute(
        text(
            "INSERT INTO catalog.admin_audit (admin_name, action, gtin, product_id) "
            "VALUES (:name, :action, :gtin, :product)"
        ),
        {"name": admin_name, "action": action, "gtin": gtin, "product": product_id},
    )
    return decision
