"""openFDA products and RxNorm compositions together: the link is made only when the SCD row
exists, and a later openFDA run re-links (docs/phase4-plan.md 4.4)."""

from __future__ import annotations

from pathlib import Path

from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from catalog.importers.loader import run_import
from catalog.importers.openfda_ndc import OpenFdaNdcImporter
from catalog.importers.rxnorm import RxNormImporter
from tests.importers.support import rows
from tests.importers.test_openfda_ndc import DATA_FILE
from tests.importers.test_openfda_ndc import SNAPSHOT as OPENFDA
from tests.importers.test_rxnorm import SNAPSHOT as RXNORM

Sessions = async_sessionmaker[AsyncSession]
LINKED = (
    "SELECT c.source, c.source_key FROM catalog.products p "
    "JOIN catalog.compositions c ON c.id = p.composition_id WHERE p.source_key = '99999-111'"
)


async def test_with_rxnorm_imported_first_the_product_links_to_the_scd(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, RxNormImporter(), RXNORM)

    result = await run_import(sessionmaker, OpenFdaNdcImporter(), OPENFDA)

    assert result.counts["products_unlinked"] == 0
    # rxcui list is ["900002", "900001"]: the SBD is not a composition, the SCD is.
    assert [tuple(r) for r in await rows(engine, LINKED)] == [("rxnorm", "900001")]


async def test_a_later_openfda_run_relinks_after_rxnorm_arrives(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    first = await run_import(sessionmaker, OpenFdaNdcImporter(), OPENFDA)
    assert first.counts["products_unlinked"] == 0
    assert [r[0] for r in await rows(engine, LINKED)] == ["openfda_ndc"]

    await run_import(sessionmaker, RxNormImporter(), RXNORM)
    second = await run_import(sessionmaker, OpenFdaNdcImporter(), OPENFDA)

    assert second.counts["products"]["updated"] == 1
    assert second.counts["products_unlinked"] == 0
    assert [tuple(r) for r in await rows(engine, LINKED)] == [("rxnorm", "900001")]


async def test_importing_openfda_does_not_withdraw_rxnorm_rows(
    sessionmaker: Sessions, engine: AsyncEngine
) -> None:
    await run_import(sessionmaker, RxNormImporter(), RXNORM)
    await run_import(sessionmaker, OpenFdaNdcImporter(), OPENFDA)

    found = await rows(
        engine, "SELECT count(*) FROM catalog.compositions WHERE withdrawn_at IS NOT NULL"
    )
    assert found[0][0] == 0


async def test_a_product_whose_rxcuis_exist_nowhere_links_to_its_local_composition(
    sessionmaker: Sessions, engine: AsyncEngine, tmp_path: Path
) -> None:
    await run_import(sessionmaker, RxNormImporter(), RXNORM)
    snapshot = tmp_path / "snap"
    snapshot.mkdir()
    text = (OPENFDA / DATA_FILE).read_text(encoding="utf-8")
    text = text.replace('"900002", "900001"', '"123456", "123457"')
    (snapshot / DATA_FILE).write_text(text, encoding="utf-8")

    result = await run_import(sessionmaker, OpenFdaNdcImporter(), snapshot)

    assert result.counts["products_unlinked"] == 0
    assert [r[0] for r in await rows(engine, LINKED)] == ["openfda_ndc"]
