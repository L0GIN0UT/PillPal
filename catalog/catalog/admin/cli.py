"""``python -m catalog.admin disputes list | resolve <gtin> --action ... [--product ...]``.

For operators without HTTP access to the private listener: it talks to the database the
container is configured for (ADR 0014 section 5). Output is JSON lines of catalog data and counts;
errors are ``error: <stable code>`` on stderr, never a traceback (it could quote record text).
Every ``resolve`` is audited as ``cli``.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid
from collections.abc import Sequence

from catalog.api.admin import shareable_gtin14
from catalog.config import Settings
from catalog.db.session import create_engine, create_sessionmaker
from catalog.errors import AppError
from catalog.services.decisions import AdminAction, DecisionError, resolve
from catalog.services.disputes import list_disputes

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
CLI_ADMIN_NAME = "cli"
PAGE = 100


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m catalog.admin")
    commands = parser.add_subparsers(dest="command", required=True)
    disputes = commands.add_parser("disputes", help="open disputes").add_subparsers(
        dest="subcommand", required=True
    )
    disputes.add_parser("list", help="print every disputed GTIN with its candidates")
    one = commands.add_parser("resolve", help="promote, reject or lock one GTIN")
    one.add_argument("gtin")
    one.add_argument("--action", required=True, choices=["promote", "reject", "lock"])
    one.add_argument("--product", type=uuid.UUID)
    return parser


async def _list(settings: Settings) -> int:
    engine = create_engine(settings)
    try:
        after = ""
        while True:
            async with create_sessionmaker(engine)() as session, session.begin():
                page = await list_disputes(session, after, PAGE)
            for dispute in page.items:
                print(dispute.model_dump_json())
            if page.next_after is None:
                return EXIT_OK
            after = page.next_after
    finally:
        await engine.dispose()


async def _resolve(
    settings: Settings, gtin: str, action: AdminAction, product: uuid.UUID | None
) -> int:
    engine = create_engine(settings)
    try:
        async with create_sessionmaker(engine)() as session, session.begin():
            decision = await resolve(session, gtin, action, product, CLI_ADMIN_NAME)
    except DecisionError as exc:
        print(f"error: {exc.code}", file=sys.stderr)
        return EXIT_FAILED
    finally:
        await engine.dispose()
    print(
        json.dumps(
            {
                "gtin": gtin,
                "status": decision.status,
                "product_id": None if decision.product_id is None else str(decision.product_id),
                "decided_by": decision.decided_by,
                "reason_code": decision.reason_code,
            },
            sort_keys=True,
        )
    )
    return EXIT_OK


def main(argv: Sequence[str] | None = None, settings: Settings | None = None) -> int:
    args = _parser().parse_args(argv)
    settings = settings or Settings()
    if args.command == "disputes":
        return asyncio.run(_list(settings))
    try:
        gtin = shareable_gtin14(args.gtin)
    except AppError as exc:
        print(f"error: {exc.code}", file=sys.stderr)
        return EXIT_USAGE
    try:
        return asyncio.run(_resolve(settings, gtin, args.action, args.product))
    except Exception:  # never a traceback: it could quote record text
        print("error: resolve_failed", file=sys.stderr)
        return EXIT_FAILED
