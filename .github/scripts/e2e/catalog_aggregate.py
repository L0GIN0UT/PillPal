"""Test-only trigger of the regional backend's catalog aggregate (milestone 4.12).

In production the ARQ worker pushes the counted links to the catalog hourly
(`app.worker`, `app.services.catalog_contributions`). The host e2e has no worker, so this script
runs the very same function once, against the e2e database and the e2e catalog:

1. it moves the accounts' creation time back, because only accounts older than
   CATALOG_CONTRIBUTION_MIN_ACCOUNT_AGE_DAYS count (owner decision D8) and the setting cannot be
   configured below one day; only the synthetic `e2e-catalog-*` accounts are touched;
2. it pushes one complete snapshot (`push_gtin_confirmations`).

Run from `backend/` with the backend's environment (DATABASE_URL, REGION, JWT_SECRET,
CATALOG_INTERNAL_URL, CATALOG_INGEST_TOKEN, CATALOG_CONTRIBUTIONS_ENABLED):

    uv run python ../.github/scripts/e2e/catalog_aggregate.py

It prints counts only (never a number, id or address) and exits non-zero on failure.
"""

import asyncio
import sys
from datetime import UTC, datetime

from sqlalchemy import text

from app.catalog_client import CatalogIngestClient
from app.config import Settings
from app.db.session import create_engine, create_sessionmaker
from app.services.catalog_contributions import push_gtin_confirmations

SYNTHETIC_EMAIL_PATTERN = "e2e-catalog-%@example.com"
# Beyond the account age of any configuration the e2e uses.
BACKDATE_DAYS = 30


async def main() -> int:
    settings = Settings()
    if not settings.catalog_contributions_enabled:
        print("catalog_aggregate: CATALOG_CONTRIBUTIONS_ENABLED is off", file=sys.stderr)
        return 2
    engine = create_engine(settings)
    maker = create_sessionmaker(engine)
    client = CatalogIngestClient(settings)
    try:
        async with maker() as session, session.begin():
            result = await session.execute(
                text(
                    "UPDATE users SET created_at = created_at - make_interval(days => :days) "
                    "WHERE lower(email) LIKE :pattern"
                ),
                {"days": BACKDATE_DAYS, "pattern": SYNTHETIC_EMAIL_PATTERN},
            )
            print(f"catalog_aggregate: accounts_backdated={result.rowcount}")
        sent = await push_gtin_confirmations(maker, settings, client, datetime.now(UTC))
        print(f"catalog_aggregate: items_sent={sent}")
    finally:
        await client.aclose()
        await engine.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
