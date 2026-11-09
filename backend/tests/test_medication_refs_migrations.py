"""Revisions 0014 (catalog references, consent) and 0015 (manual ingredients) of ``medications``."""

from __future__ import annotations

import uuid

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from app.db.base import Base
from app.db.medication_checks import CATALOG_CHECKS
from app.db.models import Medication  # noqa: F401 - registers the tables on Base.metadata
from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db

DB = "pillpal_test_refs_migrations"
REFS = "0014_medication_catalog_refs"
INGREDIENTS = "0015_med_manual_ingredients"
INDEX_REVISION = "0016_med_catalog_ref_index"
BEFORE = "0013_dose_events_detector_idx"
REF_COLUMNS = {
    "catalog_product_id",
    "catalog_package_id",
    "catalog_composition_id",
    "gtin",
    "gtin_link_shared",
    "gtin_link_consent_version",
    "gtin_link_consented_at",
}
INDEX = "ix_medications_gtin_link_shared"


def test_revision_ids_fit_alembic_version_column() -> None:
    assert len(REFS) <= 32
    assert len(INGREDIENTS) <= 32
    assert len(INDEX_REVISION) <= 32


async def _columns(engine: AsyncEngine) -> set[str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_name = 'medications'"
            )
        )
        return {r[0] for r in rows}


async def _indexes(engine: AsyncEngine) -> dict[str, str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'medications'")
        )
        return {r[0]: r[1] for r in rows}


async def _insert_medication(engine: AsyncEngine) -> str:
    """A bare row (user, self profile, medication) written with SQL, as an old backend had it."""
    uid, pid, mid = (str(uuid.uuid4()) for _ in range(3))
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO users (id, email, password_hash, region, locale) "
                "VALUES (:u, :e, 'x', 'ru', 'en')"
            ),
            {"u": uid, "e": f"{uid}@example.com"},
        )
        await conn.execute(
            text(
                "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
                "client_updated_at) VALUES (:p, :u, 'self', 'Synthetic', 'UTC', now())"
            ),
            {"p": pid, "u": uid},
        )
        await conn.execute(
            text(
                "INSERT INTO medications (id, profile_id, name, client_updated_at) "
                "VALUES (:m, :p, 'Synthetic Tablet', now())"
            ),
            {"m": mid, "p": pid},
        )
    return mid


async def test_references_revision_round_trips_without_touching_rows() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    try:
        mid = await _insert_medication(engine)
        assert not REF_COLUMNS & await _columns(engine)
        run_migrations(url, REFS)
        assert await _columns(engine) >= REF_COLUMNS
        assert "manual_ingredients" not in await _columns(engine)
        assert INDEX not in await _indexes(engine)  # revision 0016
        async with engine.connect() as conn:
            found = (
                await conn.execute(
                    text("SELECT gtin, gtin_link_shared FROM medications WHERE id = :i"), {"i": mid}
                )
            ).one()
        assert tuple(found) == (None, False)  # existing rows are untouched and not opted in
        downgrade(url, BEFORE)
        assert not REF_COLUMNS & await _columns(engine)
        run_migrations(url, REFS)
        assert await _columns(engine) >= REF_COLUMNS
    finally:
        await engine.dispose()


async def test_the_index_revision_builds_the_partial_index_and_round_trips() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, INGREDIENTS)
    engine = create_async_engine(url)
    try:
        assert INDEX not in await _indexes(engine)
        run_migrations(url, INDEX_REVISION)
        definition = (await _indexes(engine))[INDEX]
        assert "(gtin, catalog_product_id)" in definition
        assert "gtin_link_shared" in definition
        assert "deleted_at IS NULL" in definition
        downgrade(url, INGREDIENTS)
        assert INDEX not in await _indexes(engine)
        downgrade(url, INGREDIENTS)  # repeatable: IF EXISTS
        run_migrations(url, INDEX_REVISION)
        assert INDEX in await _indexes(engine)
    finally:
        await engine.dispose()


async def test_the_index_revision_replaces_an_invalid_leftover() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, INGREDIENTS)
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:  # what a failed CONCURRENTLY build leaves behind
            await conn.execute(text(f"CREATE INDEX {INDEX} ON medications (gtin)"))
            await conn.execute(
                text(
                    "UPDATE pg_index SET indisvalid = false WHERE indexrelid = CAST(:n AS regclass)"
                ),
                {"n": INDEX},
            )
        run_migrations(url, INDEX_REVISION)
        async with engine.connect() as conn:
            valid = await conn.scalar(
                text("SELECT indisvalid FROM pg_index WHERE indexrelid = CAST(:n AS regclass)"),
                {"n": INDEX},
            )
        assert valid is True
        assert "gtin_link_shared" in (await _indexes(engine))[INDEX]
    finally:
        await engine.dispose()


async def _check_definitions(engine: AsyncEngine) -> dict[str, str]:
    """CHECK name (without the ``ck_medications_`` prefixes) -> normalized definition."""
    async with engine.connect() as conn:
        rows = await conn.execute(
            text(
                "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint "
                "WHERE conrelid = 'medications'::regclass AND contype = 'c'"
            )
        )
        return {r[0].replace("ck_medications_", ""): r[1] for r in rows}


async def test_the_checks_migrations_create_match_the_model() -> None:
    """The CHECK SQL is written in the model and twice in revisions: it must not drift."""
    migrated_url = await _recreate_db(DB)
    run_migrations(migrated_url, "head")
    model_url = await _recreate_db(DB + "_model")
    migrated, built = create_async_engine(migrated_url), create_async_engine(model_url)
    try:
        async with built.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        from_migrations = await _check_definitions(migrated)
        from_model = await _check_definitions(built)
        owned = {"tombstone_erased", *CATALOG_CHECKS}
        assert owned <= from_migrations.keys()
        assert owned <= from_model.keys()
        for name in owned:
            assert from_migrations[name] == from_model[name], name
    finally:
        await migrated.dispose()
        await built.dispose()


async def test_manual_ingredients_revision_round_trips() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, REFS)
    engine = create_async_engine(url)
    try:
        assert "manual_ingredients" not in await _columns(engine)
        run_migrations(url, INGREDIENTS)
        assert "manual_ingredients" in await _columns(engine)
        downgrade(url, REFS)
        assert "manual_ingredients" not in await _columns(engine)
        assert await _columns(engine) >= REF_COLUMNS
        run_migrations(url, INGREDIENTS)
        assert "manual_ingredients" in await _columns(engine)
    finally:
        await engine.dispose()


async def test_the_tombstone_check_covers_the_new_columns_from_each_revision() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, REFS)
    engine = create_async_engine(url)
    try:
        mid = await _insert_medication(engine)
        erase = (
            "UPDATE medications SET name = NULL, deleted_at = now(), "
            "catalog_product_id = gen_random_uuid() WHERE id = :i"
        )
        with pytest.raises(IntegrityError, match="tombstone_erased"):
            async with engine.begin() as conn:
                await conn.execute(text(erase), {"i": mid})
        run_migrations(url, INGREDIENTS)
        with pytest.raises(IntegrityError, match="tombstone_erased"):
            async with engine.begin() as conn:
                await conn.execute(
                    text(
                        "UPDATE medications SET name = NULL, deleted_at = now(), "
                        "manual_ingredients = '[]'::jsonb WHERE id = :i"
                    ),
                    {"i": mid},
                )
    finally:
        await engine.dispose()


async def test_the_whole_chain_round_trips() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, "head")
    engine = create_async_engine(url)
    try:
        downgrade(url, BEFORE)
        assert not (REF_COLUMNS | {"manual_ingredients"}) & await _columns(engine)
        run_migrations(url, "head")
        assert (REF_COLUMNS | {"manual_ingredients"}) <= await _columns(engine)
    finally:
        await engine.dispose()
