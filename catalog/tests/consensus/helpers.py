"""Helpers of the ingest tests: request bodies and the PUT call."""

from __future__ import annotations

import uuid
from typing import Any

from httpx import AsyncClient

from tests.consensus.conftest import RU_SECRET


def bearer(secret: str = RU_SECRET) -> dict[str, str]:
    return {"Authorization": f"Bearer {secret}"}


def item(gtin: str, product: uuid.UUID, count: int = 2) -> dict[str, Any]:
    return {"gtin": gtin, "product_id": str(product), "count": count}


async def put(
    client: AsyncClient,
    items: list[dict[str, Any]],
    *,
    region: str = "ru",
    generation: int = 1,
    page: int = 0,
    complete: bool = True,
    secret: str = RU_SECRET,
) -> Any:
    return await client.put(
        f"/internal/v1/regions/{region}/gtin-confirmations",
        json={"generation": generation, "page": page, "complete": complete, "items": items},
        headers=bearer(secret),
    )
