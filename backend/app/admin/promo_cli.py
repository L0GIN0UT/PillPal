"""The ``promo`` commands of ``python -m app.admin`` (ADR 0018 section 5).

``create`` prints each code once, on stdout, after the commit; nothing here logs a code or a
digest, and ``list`` never reads the digest column. Exit codes as in ``app.admin.cli``.
"""

from __future__ import annotations

import argparse
import uuid
from datetime import datetime
from typing import Any, TextIO

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.admin.arg_types import (
    account_id_arg,
    actor_arg,
    count_arg,
    expires_arg,
    grant_days_arg,
    label_arg,
    list_limit_arg,
    max_activations_arg,
)
from app.admin.promo import (
    NewCampaign,
    PromoNotFound,
    PromoSummary,
    create_codes,
    disable_code,
    list_codes,
)
from app.config import Settings
from app.domain.entitlements import ENTITLEMENT_KINDS
from app.observability import get_logger
from app.services.admin_audit import Operator

_log = get_logger("pillpal.admin")

EXIT_OK = 0
EXIT_REFUSED = 2
DEFAULT_LIST_ROWS = 100


def add_promo_parsers(areas: Any) -> None:
    promo = areas.add_parser("promo", help="create, list or disable promo codes")
    commands = promo.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create", help="create codes; they are printed once")
    create.add_argument(
        "--label", type=label_arg, required=True, help="campaign name, no personal data"
    )
    create.add_argument("--kind", choices=ENTITLEMENT_KINDS, required=True)
    create.add_argument("--max-activations", type=max_activations_arg, required=True)
    create.add_argument("--expires", type=expires_arg, help="ISO 8601 with offset; default: never")
    create.add_argument(
        "--grant-days", type=grant_days_arg, help="entitlement length; default: no expiry"
    )
    create.add_argument("--count", type=count_arg, default=1, help="codes per run, at most 100")
    create.add_argument("--actor", type=actor_arg, required=True, help="operator handle")

    listing = commands.add_parser("list", help="list codes (metadata only, never the codes)")
    listing.add_argument("--limit", type=list_limit_arg, default=DEFAULT_LIST_ROWS)

    disable = commands.add_parser("disable", help="stop a code from being redeemed")
    disable.add_argument("code_id", type=account_id_arg, help="the id printed by create or list")
    disable.add_argument("--actor", type=actor_arg, required=True, help="operator handle")


def _expiry(value: datetime | None) -> str:
    return "-" if value is None else value.isoformat()


def _line(row: PromoSummary) -> str:
    days = "-" if row.grant_days is None else str(row.grant_days)
    return (
        f"{row.id} {row.state} {row.kind} {row.activations}/{row.max_activations} "
        f"days={days} expires={_expiry(row.expires_at)} label={row.label}"
    )


async def run_promo(
    args: argparse.Namespace,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    who: Operator | None,
    now: datetime,
    out: TextIO,
    err: TextIO,
) -> int:
    """Run one promo command against an open session factory; the process exit code."""
    if args.command == "list":
        for row in await list_codes(maker, limit=args.limit, now=now):
            out.write(_line(row) + "\n")
        return EXIT_OK
    if who is None:  # argparse requires --actor for these; kept as a guard
        err.write("--actor is required\n")
        return EXIT_REFUSED
    if args.command == "disable":
        return await _disable(args.code_id, maker, who, now, out, err)
    return await _create(args, maker, settings, who, now, out, err)


async def _create(
    args: argparse.Namespace,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    who: Operator,
    now: datetime,
    out: TextIO,
    err: TextIO,
) -> int:
    key = settings.promo_key_bytes()
    if key is None:
        err.write("PROMO_CODE_HMAC_KEY is not set\n")
        return EXIT_REFUSED
    promo_codes = await create_codes(
        maker,
        key=key,
        length=settings.promo_code_length,
        count=args.count,
        campaign=NewCampaign(
            label=args.label,
            kind=args.kind,
            max_activations=args.max_activations,
            grant_days=args.grant_days,
            expires_at=args.expires,
        ),
        operator=who,
        now=now,
    )
    # Ids and the count only: the codes are on stdout and nowhere else.
    _log.info("admin_promo_create", count=len(promo_codes), kind=args.kind, actor=who.actor)
    for code_id, promo_code in promo_codes:
        out.write(f"{code_id} {promo_code}\n")
    err.write("These codes are shown once and cannot be recovered; store them now.\n")
    return EXIT_OK


async def _disable(
    code_id: uuid.UUID,
    maker: async_sessionmaker[AsyncSession],
    who: Operator,
    now: datetime,
    out: TextIO,
    err: TextIO,
) -> int:
    try:
        changed = await disable_code(maker, code_id=code_id, operator=who, now=now)
    except PromoNotFound:
        err.write("no such promo code\n")
        return EXIT_REFUSED
    _log.info("admin_promo_disable", changed=changed, actor=who.actor)
    out.write(f"{'disabled' if changed else 'already disabled'}: {code_id}\n")
    return EXIT_OK
