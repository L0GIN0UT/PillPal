"""POST /v1/products/get: one card, no batch (a batch would enumerate a medication list)."""

from __future__ import annotations

from fastapi import APIRouter, Request
from sqlalchemy.ext.asyncio import AsyncSession

from catalog.api.guards import PUBLIC_DEPENDENCIES
from catalog.db.reads import run_read
from catalog.errors import not_found
from catalog.schemas.cards import ProductCard, ProductGetRequest
from catalog.services.cards import product_card

router = APIRouter(prefix="/v1/products", tags=["products"], dependencies=PUBLIC_DEPENDENCIES)


@router.post("/get")
async def get_product(body: ProductGetRequest, request: Request) -> ProductCard:
    """The card of one product, withdrawn rows included (user medications reference them)."""

    async def work(session: AsyncSession) -> ProductCard:
        card = await product_card(session, body.id)
        if card is None:
            raise not_found()
        return card

    return await run_read(request, work)
