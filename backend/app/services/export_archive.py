"""Account data export: collect the rows of one account and pack them into a zip archive.

The policy lives in ``app.services.personal_data`` (``TableInfo.export*``); the format is
``docs/spec/export.md``. Rows are found through ``owner_ref`` without table specific code:

* ``user`` - the owner column holds ``users.id``;
* ``profile`` - it holds the id of a profile the account owns (a profile inherited through the
  D1 transfer is owned by the heir, so it is included; a profile the account only co-guards is
  not);
* ``medication`` - it holds the id of a medication of such a profile.

Nothing else is read: another account's data reaches the archive only as an opaque id in a
relation row. Credentials are never exported (``export_exclude``). ``collect_account_data`` is
the only part that touches the database; ``build_archive`` is pure and CPU bound, so callers run
it through ``asyncio.to_thread``. This module logs nothing: the archive is medical data.
"""

from __future__ import annotations

import json
import tempfile
import uuid
import zipfile
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

from sqlalchemy import ColumnElement, Select, Table, select, union
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import alerts, consents, entitlements, exports, identities, promo, push, relatives
from app.db.base import Base
from app.services.personal_data import TABLE_CLASSIFICATION, OwnerRef, TableInfo

# Importing the model modules registers every table in ``Base.metadata``.
MODEL_MODULES = (alerts, consents, entitlements, exports, identities, promo, push, relatives)
FORMAT_VERSION = 1
MANIFEST_NAME = "manifest.json"
# Rows fetched per round trip while streaming one table.
FETCH_BATCH = 500
# The archive is built in a spooled file: memory up to this size, a temporary file beyond it.
SPOOL_MAX_BYTES = 8 * 1024 * 1024
# Zip member timestamps and permissions are fixed so that equal data gives equal bytes.
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
ZIP_UNIX = 3
ZIP_MEMBER_MODE = 0o600 << 16
# One consistent snapshot across all tables, and no write possible from this session.
SNAPSHOT_OPTIONS = {"isolation_level": "REPEATABLE READ", "postgresql_readonly": True}


@dataclass(frozen=True)
class ExportData:
    """Rows per exported table, as returned by the database (not yet JSON friendly)."""

    tables: Mapping[str, Sequence[dict[str, Any]]]


def exported_table_names() -> list[str]:
    return sorted(name for name, info in TABLE_CLASSIFICATION.items() if info.export == "rows")


def exported_columns(table: str, *, with_excluded: bool = False) -> tuple[str, ...]:
    """Column names of ``table`` that go into the archive, in table order."""
    excluded = () if with_excluded else TABLE_CLASSIFICATION[table].export_exclude
    return tuple(c.name for c in Base.metadata.tables[table].columns if c.name not in excluded)


def _owned_profiles(user_id: uuid.UUID) -> Select[tuple[uuid.UUID]]:
    profiles = Base.metadata.tables["profiles"]
    return select(profiles.c.id).where(profiles.c.owner_user_id == user_id)


def _owned_medications(user_id: uuid.UUID) -> Select[tuple[uuid.UUID]]:
    medications = Base.metadata.tables["medications"]
    return select(medications.c.id).where(medications.c.profile_id.in_(_owned_profiles(user_id)))


def _belongs(table: Table, column: str, ref: OwnerRef, user_id: uuid.UUID) -> ColumnElement[bool]:
    owner = table.c[column]
    if ref == "user":
        return owner == user_id
    if ref == "profile":
        return owner.in_(_owned_profiles(user_id))
    return owner.in_(_owned_medications(user_id))


def _row_filter(table: Table, info: TableInfo, user_id: uuid.UUID) -> ColumnElement[bool]:
    """Rows of the account; several ways to belong are a UNION of ids (one index scan each)."""
    if info.owner_column is None:
        raise RuntimeError(f"{table.name}: an exported table needs an owner column")
    ways = [(info.owner_column, info.owner_ref), *info.export_also]
    if len(ways) == 1:
        return _belongs(table, *ways[0], user_id)
    if len(table.primary_key.columns) != 1:
        raise RuntimeError(f"{table.name}: export_also needs a single-column primary key")
    key = next(iter(table.primary_key.columns))
    ids = union(*(select(key).where(_belongs(table, c, r, user_id)) for c, r in ways))
    return key.in_(ids)


async def _collect_table(
    session: AsyncSession, name: str, user_id: uuid.UUID
) -> list[dict[str, Any]]:
    table = Base.metadata.tables[name]
    info = TABLE_CLASSIFICATION[name]
    columns = [table.c[column] for column in exported_columns(name)]
    stmt = (
        select(*columns)
        .where(_row_filter(table, info, user_id))
        .order_by(*table.primary_key.columns)
        .execution_options(yield_per=FETCH_BATCH)
    )
    result = await session.stream(stmt)
    return [dict(row) async for row in result.mappings()]


async def collect_account_data(session: AsyncSession, user_id: uuid.UUID) -> ExportData:
    """Read the account's rows of every exported table in one consistent snapshot.

    Must be the first use of the session's transaction (the isolation level cannot change
    afterwards). Read only; the caller owns the session.
    """
    await session.connection(execution_options=SNAPSHOT_OPTIONS)
    return ExportData(
        {name: await _collect_table(session, name, user_id) for name in exported_table_names()}
    )


def _json_default(value: object) -> str:
    if isinstance(value, datetime):
        return value.astimezone(UTC).isoformat()
    if isinstance(value, uuid.UUID | Decimal):
        return str(value)
    raise TypeError(f"cannot export {type(value).__name__}")


def _dump(value: object) -> bytes:
    return json.dumps(value, default=_json_default, ensure_ascii=False, sort_keys=True).encode()


def _write(archive: zipfile.ZipFile, name: str, payload: bytes) -> None:
    info = zipfile.ZipInfo(name, date_time=ZIP_EPOCH)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = ZIP_UNIX
    info.external_attr = ZIP_MEMBER_MODE
    archive.writestr(info, payload)


class ArchiveTooLarge(Exception):
    """The archive passed ``max_bytes`` while it was being written."""


def build_archive(
    data: ExportData, *, region: str, now: datetime, max_bytes: int | None = None
) -> bytes:
    """Zip ``manifest.json`` first, then ``tables/<table>.json`` in name order. Pure.

    With ``max_bytes`` the build stops with :class:`ArchiveTooLarge` as soon as the running size
    passes it (the finished archive is checked by the caller as well: the central directory
    follows the members).

    ``data`` must hold exactly the exported tables (an empty list for a table without rows):
    a missing table would silently hide data from the user.
    """
    names = exported_table_names()
    if set(data.tables) != set(names):
        raise ValueError("the data does not match the exported tables")
    manifest = {
        "format_version": FORMAT_VERSION,
        "region": region,
        "generated_at": now.astimezone(UTC).isoformat(),
        "tables": {name: len(data.tables[name]) for name in names},
    }
    with tempfile.SpooledTemporaryFile(max_size=SPOOL_MAX_BYTES) as spool:
        with zipfile.ZipFile(spool, "w") as archive:
            _write(archive, MANIFEST_NAME, _dump(manifest))
            for name in names:
                _write(archive, f"tables/{name}.json", _dump(data.tables[name]))
                if max_bytes is not None and spool.tell() > max_bytes:
                    raise ArchiveTooLarge
        spool.seek(0)
        return spool.read()
