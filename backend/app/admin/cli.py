"""Argument parsing and dispatch of ``python -m app.admin``.

``entitlement grant`` reads the e-mail from **stdin** (first line), so it never lands in argv,
shell history or a process list; nothing here prints or logs an e-mail. Exit codes: 0 done (also
a no-op replay), 1 database error, 2 usage error or an unknown account (a grant also refuses
a pending-deletion account; a revoke does not). Output goes to stdout with
account and entitlement ids only.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from collections.abc import Sequence
from datetime import UTC, datetime
from typing import TextIO

from pydantic_core import PydanticCustomError
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.admin.arg_types import account_id_arg, actor_arg, expires_arg
from app.admin.entitlements import AccountNotFound, grant_entitlement, revoke_entitlements
from app.admin.promo_cli import add_promo_parsers, run_promo
from app.config import Settings
from app.db.session import create_engine, create_sessionmaker
from app.domain.entitlements import ENTITLEMENT_KINDS
from app.observability import configure_logging, get_logger
from app.schemas.auth import normalize_email
from app.services.admin_audit import Operator, current_operator

_log = get_logger("pillpal.admin")

EXIT_OK = 0
EXIT_REFUSED = 2
EXIT_FAILED = 1
MAX_EMAIL_LENGTH = 320


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m app.admin", description="PillPal operator commands (audited)."
    )
    areas = parser.add_subparsers(dest="area", required=True)
    entitlement = areas.add_parser("entitlement", help="grant or revoke an entitlement")
    commands = entitlement.add_subparsers(dest="command", required=True)

    grant = commands.add_parser("grant", help="grant to the account whose e-mail is on stdin")
    grant.add_argument("--kind", choices=ENTITLEMENT_KINDS, required=True)
    grant.add_argument("--expires", type=expires_arg, help="ISO 8601 with offset; default: never")
    grant.add_argument(
        "--actor", type=actor_arg, required=True, help="operator handle, not an e-mail"
    )

    revoke = commands.add_parser("revoke", help="revoke the entitlements of an account")
    revoke.add_argument("--account-id", type=account_id_arg, required=True)
    revoke.add_argument("--kind", choices=ENTITLEMENT_KINDS, required=True)
    revoke.add_argument(
        "--actor", type=actor_arg, required=True, help="operator handle, not an e-mail"
    )
    add_promo_parsers(areas)
    return parser


def _say(out: TextIO, text: str) -> None:
    out.write(text + "\n")


async def _grant(
    maker: async_sessionmaker[AsyncSession],
    args: argparse.Namespace,
    email: str,
    who: Operator,
    now: datetime,
    out: TextIO,
) -> None:
    result = await grant_entitlement(
        maker, email=email, kind=args.kind, expires_at=args.expires, operator=who, now=now
    )
    _log.info(
        "admin_entitlement_grant",
        kind=args.kind,
        created=result.created,
        actor=who.actor,
    )
    state = "granted" if result.created else "already granted"
    _say(out, f"{state}: account {result.account_id} entitlement {result.entitlement_id}")


async def _revoke(
    maker: async_sessionmaker[AsyncSession],
    args: argparse.Namespace,
    who: Operator,
    now: datetime,
    out: TextIO,
) -> None:
    result = await revoke_entitlements(
        maker, account_id=args.account_id, kind=args.kind, operator=who, now=now
    )
    _log.info(
        "admin_entitlement_revoke",
        kind=args.kind,
        revoked=result.revoked,
        actor=who.actor,
    )
    _say(out, f"revoked {result.revoked}: account {result.account_id}")


async def run_admin(
    argv: Sequence[str],
    *,
    stdin: TextIO,
    settings: Settings,
    stdout: TextIO | None = None,
    stderr: TextIO | None = None,
    operator: Operator | None = None,
    now: datetime | None = None,
) -> int:
    """Run one command; the process exit code. ``operator`` and ``now`` are injectable."""
    out, err = stdout or sys.stdout, stderr or sys.stderr
    try:
        args = build_parser().parse_args(list(argv))
    except SystemExit as exc:  # argparse exits for usage errors (2) and --help (0)
        return exc.code if isinstance(exc.code, int) else EXIT_REFUSED
    moment = now or datetime.now(UTC)
    if args.area == "promo":
        actor = getattr(args, "actor", None)  # ``promo list`` reads only and has none
        who = operator or (current_operator(actor) if actor else None)
        return await _run_promo(args, settings, who, moment, out, err)
    who = operator or current_operator(args.actor)
    email = ""
    if args.command == "grant":
        email = stdin.readline().strip()
        try:
            if not email or len(email) > MAX_EMAIL_LENGTH:
                raise ValueError
            email = normalize_email(email)  # the registration rule: what is stored is looked up
        except (ValueError, PydanticCustomError):
            _say(err, "expected a valid account e-mail on the first line of stdin")
            return EXIT_REFUSED
        if args.expires is not None and args.expires <= moment:
            _say(err, "--expires must be in the future")
            return EXIT_REFUSED

    engine = create_engine(settings)
    try:
        maker = create_sessionmaker(engine)
        if args.command == "grant":
            await _grant(maker, args, email, who, moment, out)
        else:
            await _revoke(maker, args, who, moment, out)
    except AccountNotFound:
        _say(err, "no such account, or it is pending deletion")
        return EXIT_REFUSED
    except SQLAlchemyError as exc:
        # The type only: the engine hides parameters, and a message may still name a value.
        _say(err, f"database error: {type(exc).__name__}")
        return EXIT_FAILED
    finally:
        await engine.dispose()
    return EXIT_OK


async def _run_promo(
    args: argparse.Namespace,
    settings: Settings,
    who: Operator | None,
    moment: datetime,
    out: TextIO,
    err: TextIO,
) -> int:
    if getattr(args, "expires", None) is not None and args.expires <= moment:
        _say(err, "--expires must be in the future")
        return EXIT_REFUSED
    engine = create_engine(settings)
    try:
        return await run_promo(args, create_sessionmaker(engine), settings, who, moment, out, err)
    except SQLAlchemyError as exc:
        _say(err, f"database error: {type(exc).__name__}")
        return EXIT_FAILED
    finally:
        await engine.dispose()


def main(argv: Sequence[str] | None = None) -> int:
    settings = Settings()
    configure_logging(settings.log_level)
    return asyncio.run(
        run_admin(sys.argv[1:] if argv is None else argv, stdin=sys.stdin, settings=settings)
    )
