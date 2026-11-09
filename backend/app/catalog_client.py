"""HTTP client of the catalog's private ingest endpoint (ADR 0014 section 3).

The only outbound call that carries anything derived from user data, so it is narrow on purpose:
one ``PUT`` per page with ``{generation, page, complete, items: [{gtin, product_id, count}]}``,
the region's bearer token and nothing else (no cookies, no user agent of the app, no device
header). ``https`` is required in strict environments (``Settings`` refuses ``http`` there).
Failures are an exception carrying the HTTP status only: a response body is never read into a
message, and no URL or token reaches a log line.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import TYPE_CHECKING, Any

import httpx

from app.config import Settings

if TYPE_CHECKING:
    from app.services.catalog_contributions import Confirmation


class CatalogUploadError(Exception):
    """A page was not accepted. ``status_code`` is ``None`` for a transport failure."""

    def __init__(self, status_code: int | None) -> None:
        super().__init__(f"catalog ingest failed ({status_code})")
        self.status_code = status_code


class CatalogIngestClient:
    def __init__(
        self, settings: Settings, transport: httpx.AsyncBaseTransport | None = None
    ) -> None:
        if settings.catalog_ingest_token is None or not settings.catalog_internal_url:
            raise ValueError("the catalog URL and the ingest token are not configured")
        self._region = settings.region
        self._http = httpx.AsyncClient(
            base_url=settings.catalog_internal_url,
            timeout=settings.catalog_http_timeout_seconds,
            headers={"Authorization": f"Bearer {settings.catalog_ingest_token.get_secret_value()}"},
            follow_redirects=False,  # the token must not follow a redirect to another host
            transport=transport,
        )

    async def put_page(
        self, *, generation: int, page: int, complete: bool, items: Sequence[Confirmation]
    ) -> None:
        body: dict[str, Any] = {
            "generation": generation,
            "page": page,
            "complete": complete,
            "items": [
                {"gtin": c.gtin, "product_id": str(c.product_id), "count": c.count} for c in items
            ],
        }
        try:
            response = await self._http.put(
                f"/internal/v1/regions/{self._region}/gtin-confirmations", json=body
            )
        except httpx.HTTPError:
            raise CatalogUploadError(None) from None
        if not response.is_success:
            raise CatalogUploadError(response.status_code)

    async def aclose(self) -> None:
        await self._http.aclose()
