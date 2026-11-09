"""Set-based statements of the loader: idempotent upserts that report what changed, the staging
table of ids seen in a run, and withdrawal of rows a snapshot no longer lists.

An upsert rewrites a row only when a content column differs (or the row was withdrawn), so a run
from an unchanged snapshot touches nothing and ``last_run_id`` keeps naming the run that last
changed a row.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID

from sqlalchemy import Table, literal_column, or_, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

CHUNK_SIZE = 1000
SEEN_TABLE = "import_seen"


@dataclass
class KindCounts:
    inserted: int = 0
    updated: int = 0
    unchanged: int = 0
    withdrawn: int = 0

    def as_dict(self) -> dict[str, int]:
        return {
            "inserted": self.inserted,
            "updated": self.updated,
            "unchanged": self.unchanged,
            "withdrawn": self.withdrawn,
        }


@dataclass
class Changes:
    """Keys written by an upsert, split by what happened."""

    inserted: set[Any] = field(default_factory=set)
    updated: set[Any] = field(default_factory=set)

    @property
    def changed(self) -> set[Any]:
        return self.inserted | self.updated


def chunks(items: Sequence[Any], size: int = CHUNK_SIZE) -> Iterable[Sequence[Any]]:
    for start in range(0, len(items), size):
        yield items[start : start + size]


async def upsert(
    session: AsyncSession,
    table: Table,
    values: Sequence[dict[str, Any]],
    *,
    conflict: Sequence[str],
    content: Sequence[str],
    key: str,
    run_id: UUID,
    counts: KindCounts,
) -> Changes:
    """Insert rows, or update those whose ``content`` columns differ. Returns the changed keys."""
    changes = Changes()
    for batch in chunks(list(values)):
        insert = pg_insert(table)
        excluded = insert.excluded
        statement = insert.on_conflict_do_update(
            index_elements=list(conflict),
            set_={
                **{name: excluded[name] for name in content},
                "withdrawn_at": None,
                "last_run_id": run_id,
            },
            where=or_(
                *(table.c[name].is_distinct_from(excluded[name]) for name in content),
                table.c.withdrawn_at.is_not(None),
            ),
        ).returning(table.c[key], literal_column("(xmax = 0)").label("inserted"))
        result = await session.execute(statement, [{**row, "last_run_id": run_id} for row in batch])
        for row_key, inserted in result.all():
            (changes.inserted if inserted else changes.updated).add(row_key)
    counts.inserted += len(changes.inserted)
    counts.updated += len(changes.updated)
    counts.unchanged += len(values) - len(changes.changed)
    return changes


async def create_seen_table(session: AsyncSession) -> None:
    await session.execute(
        text(
            f"CREATE TEMP TABLE {SEEN_TABLE} (kind text NOT NULL, key text NOT NULL, "
            "PRIMARY KEY (kind, key)) ON COMMIT DROP"
        )
    )


async def mark_seen(session: AsyncSession, kind: str, keys: Iterable[str]) -> None:
    rows = [{"kind": kind, "key": key} for key in keys]
    for batch in chunks(rows):
        await session.execute(
            text(f"INSERT INTO {SEEN_TABLE} (kind, key) VALUES (:kind, :key)"),  # noqa: S608
            list(batch),
        )


# (kind, table, key expression, extra condition): the rows a source owns. The table name doubles
# as the key of the counts.
WITHDRAWABLE = (
    ("substance", "substances", "id::text", "true"),
    ("composition", "compositions", "id::text", "true"),
    ("product", "products", "id::text", "true"),
    ("package", "packages", "id::text", "true"),
    ("gtin", "gtins", "gtin::text", "origin = 'source'"),
)


async def withdraw_unseen(session: AsyncSession, source: str, run_id: UUID, kind: str) -> int:
    """Mark the rows of ``source`` that this run did not see as withdrawn; never deletes."""
    _, table, key_expr, extra = next(w for w in WITHDRAWABLE if w[0] == kind)
    result = await session.execute(
        text(
            f"UPDATE catalog.{table} t SET withdrawn_at = now(), last_run_id = :run "  # noqa: S608
            f"WHERE t.source = :source AND t.withdrawn_at IS NULL AND {extra} "
            f"AND NOT EXISTS (SELECT 1 FROM {SEEN_TABLE} s "
            f"WHERE s.kind = :kind AND s.key = t.{key_expr}) RETURNING 1"
        ),
        {"run": run_id, "source": source, "kind": kind},
    )
    return len(result.all())
