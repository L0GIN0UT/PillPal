"""Command line of the importers: ``python -m catalog.importers run|fetch``. The owner runs it
per deployment (no scheduler in Phase 4). Output is counts and stable codes only: record text,
file names and GTINs never reach stdout, stderr or logs."""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections.abc import Sequence
from pathlib import Path

import httpx

from catalog.config import STRICT_ENVIRONMENTS, Settings
from catalog.db.session import create_engine, create_sessionmaker
from catalog.importers.archive import ArchiveRejected
from catalog.importers.base import Importer, ImporterDisabled, ImporterError
from catalog.importers.esklp import EsklpImporter
from catalog.importers.fixture import FIXTURE_SOURCE, FixtureImporter, ensure_dev_source
from catalog.importers.loader import ImportInProgress, run_import
from catalog.importers.openfda_ndc import OPENFDA_SOURCE, OpenFdaNdcImporter
from catalog.importers.rxnorm import RXNORM_SOURCE, RxNormImporter

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_REFUSED = 3
# Codes of refusals: the importer is gated or the source is not allowed here.
_REFUSALS = (ImporterDisabled, ImportInProgress)


def build_importers(
    settings: Settings,
    transport: httpx.BaseTransport | None = None,
    release: str | None = None,
    expected_sha256: str | None = None,
) -> dict[str, Importer]:
    return {
        FIXTURE_SOURCE: FixtureImporter(),
        "esklp": EsklpImporter(enabled=settings.importer_esklp_enabled),
        OPENFDA_SOURCE: OpenFdaNdcImporter(transport=transport),
        RXNORM_SOURCE: RxNormImporter(
            transport=transport, release=release, expected_sha256=expected_sha256
        ),
    }


def _parser(sources: Sequence[str]) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m catalog.importers")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="load a snapshot directory into the catalog")
    run.add_argument("--source", required=True, choices=sorted(sources))
    run.add_argument("--snapshot", required=True, type=Path)
    run.add_argument(
        "--no-withdraw",
        action="store_true",
        help="do not mark rows missing from the snapshot as withdrawn (manual partial exports)",
    )
    fetch = commands.add_parser("fetch", help="download a snapshot into a directory")
    fetch.add_argument("--source", required=True, choices=sorted(sources))
    fetch.add_argument("--out", required=True, type=Path)
    fetch.add_argument("--release", help="rxnorm only: dated release MMDDYYYY (default: current)")
    fetch.add_argument(
        "--expect-sha256", help="rxnorm only: the archive must have exactly this sha256"
    )
    return parser


async def _run(settings: Settings, importer: Importer, snapshot: Path, withdraw: bool) -> int:
    if importer.source == FIXTURE_SOURCE and settings.environment in STRICT_ENVIRONMENTS:
        print("error: fixture_source_not_allowed", file=sys.stderr)
        return EXIT_REFUSED
    engine = create_engine(settings)
    try:
        sessions = create_sessionmaker(engine)
        if importer.source == FIXTURE_SOURCE:
            async with sessions.begin() as session:
                await ensure_dev_source(session, FIXTURE_SOURCE)
        result = await run_import(
            sessions,
            importer,
            snapshot,
            withdraw_missing=withdraw,
            stale_run_minutes=settings.importer_stale_run_minutes,
        )
    finally:
        await engine.dispose()
    summary = {"run": str(result.run_id), "status": "succeeded", "counts": result.counts}
    print(json.dumps(summary, sort_keys=True))
    return EXIT_OK


def main(
    argv: Sequence[str] | None = None,
    settings: Settings | None = None,
    transport: httpx.BaseTransport | None = None,
) -> int:
    settings = settings or Settings()
    sources = list(build_importers(settings))
    args = _parser(sources).parse_args(argv)
    release = getattr(args, "release", None)
    expected = getattr(args, "expect_sha256", None)
    if (release or expected) and args.source != RXNORM_SOURCE:
        print("error: option_not_supported", file=sys.stderr)
        return EXIT_USAGE
    importer = build_importers(settings, transport, release, expected)[args.source]
    try:
        if args.command == "fetch":
            importer.ensure_enabled()
            manifest = importer.fetch(args.out)
            print(json.dumps({"source": manifest.source, "sha256": manifest.sha256}))
            return EXIT_OK
        return asyncio.run(_run(settings, importer, args.snapshot, not args.no_withdraw))
    except Exception as exc:  # the CLI never prints a traceback: it could quote record text
        if not isinstance(exc, ImporterError | ArchiveRejected):
            print("error: import_failed", file=sys.stderr)
            return EXIT_FAILED
        print(f"error: {exc.code}", file=sys.stderr)
        return EXIT_REFUSED if isinstance(exc, _REFUSALS) else EXIT_FAILED
