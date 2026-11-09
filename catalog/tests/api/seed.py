"""Direct SQL seeding of catalog rows for API tests (synthetic names only, privacy rule 9).

Independent of the importers on purpose: the API tests describe the data they need, including the
search entries, without depending on what a loader does with a snapshot.
"""

from __future__ import annotations

import re
import uuid
from collections.abc import Sequence
from dataclasses import dataclass, field
from decimal import Decimal

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.importers.ids import composition_id, package_id, product_id, substance_id

_CYRILLIC = re.compile("[Ѐ-ӿ]")
DIGEST = "b" * 64


def _lang(value: str) -> str:
    return "ru" if _CYRILLIC.search(value) else "en"


@dataclass(frozen=True)
class Ingredient:
    substance: uuid.UUID
    strength_value: Decimal | None = None
    strength_unit: str | None = None


@dataclass
class Seed:
    engine: AsyncEngine
    source: str = "openfda_ndc"
    run_id: uuid.UUID = field(default_factory=uuid.uuid4)
    _started: bool = False

    async def _exec(self, sql: str, **params: object) -> None:
        async with self.engine.begin() as conn:
            await conn.execute(text(sql), params)

    async def _ensure_run(self) -> None:
        if not self._started:
            await self._exec(
                "INSERT INTO catalog.import_runs (id, source, snapshot_sha256, status, finished_at)"
                " VALUES (:id, :s, :h, 'succeeded', now())",
                id=self.run_id,
                s=self.source,
                h=DIGEST,
            )
            self._started = True

    async def _entries(
        self, kind: str, entity: uuid.UUID, market: str, names: Sequence[str]
    ) -> None:
        for name in dict.fromkeys(names):
            await self._exec(
                "INSERT INTO catalog.search_entries (entity_kind, entity_id, market, lang, text) "
                "VALUES (:k, :i, :m, :l, :t) ON CONFLICT DO NOTHING",
                k=kind,
                i=entity,
                m=market,
                l=_lang(name),
                t=name,
            )

    async def substance(
        self,
        key: str,
        name_en: str | None,
        name_ru: str | None = None,
        *,
        market: str = "us",
        extra_names: Sequence[str] = (),
        withdrawn: bool = False,
    ) -> uuid.UUID:
        await self._ensure_run()
        sid = substance_id(self.source, key)
        await self._exec(
            "INSERT INTO catalog.substances (id, source, source_key, market, name_en, name_ru, "
            "withdrawn_at, last_run_id) VALUES (:id, :s, :k, :m, :en, :ru, "
            "CASE WHEN :w THEN now() END, :r)",
            id=sid,
            s=self.source,
            k=key,
            m=market,
            en=name_en,
            ru=name_ru,
            w=withdrawn,
            r=self.run_id,
        )
        names = [n for n in (name_en, name_ru, *extra_names) if n]
        for name in dict.fromkeys(names):
            await self._exec(
                "INSERT INTO catalog.substance_names (substance_id, lang, name, source) "
                "VALUES (:i, :l, :n, :s) ON CONFLICT DO NOTHING",
                i=sid,
                l=_lang(name),
                n=name,
                s=self.source,
            )
        await self._entries("substance", sid, market, names)
        return sid

    async def composition(
        self,
        key: str,
        ingredients: Sequence[Ingredient],
        *,
        market: str = "us",
        form_en: str | None = "tablet",
        form_ru: str | None = "таблетки",
        complete: bool = True,
    ) -> uuid.UUID:
        await self._ensure_run()
        cid = composition_id(self.source, key)
        await self._exec(
            "INSERT INTO catalog.compositions (id, source, source_key, market, form_code, "
            "form_name_en, form_name_ru, complete, identity_key, last_run_id) "
            "VALUES (:id, :s, :k, :m, 'TAB', :en, :ru, :c, :ik, :r)",
            id=cid,
            s=self.source,
            k=key,
            m=market,
            en=form_en,
            ru=form_ru,
            c=complete,
            ik=uuid.uuid5(uuid.NAMESPACE_URL, key).hex * 2,
            r=self.run_id,
        )
        for ing in ingredients:
            await self._exec(
                "INSERT INTO catalog.composition_ingredients (composition_id, substance_id, "
                "strength_value, strength_unit) VALUES (:c, :s, :v, :u)",
                c=cid,
                s=ing.substance,
                v=ing.strength_value,
                u=ing.strength_unit,
            )
        return cid

    async def product(
        self,
        key: str,
        brand: str,
        *,
        market: str = "us",
        country: str | None = "US",
        manufacturer: str | None = "Example Pharma",
        composition: uuid.UUID | None = None,
        withdrawn: bool = False,
        registration_number: str | None = None,
        packages: Sequence[tuple[str, Sequence[str]]] = (),
    ) -> uuid.UUID:
        """``packages``: ``(description, [gtin14, ...])`` pairs."""
        await self._ensure_run()
        pid = product_id(self.source, key)
        await self._exec(
            "INSERT INTO catalog.products (id, source, source_key, market, brand_name, "
            "manufacturer, country, composition_id, rx_status, registration_number, withdrawn_at, "
            "last_run_id) VALUES (:id, :s, :k, :m, :b, :mf, :c, :comp, 'otc', :reg, "
            "CASE WHEN :w THEN now() END, :r)",
            id=pid,
            s=self.source,
            k=key,
            m=market,
            b=brand,
            mf=manufacturer,
            c=country,
            comp=composition,
            reg=registration_number,
            w=withdrawn,
            r=self.run_id,
        )
        await self._entries("product", pid, market, [brand])
        for i, (description, gtins) in enumerate(packages):
            kid = package_id(self.source, f"{key}-{i}")
            await self._exec(
                "INSERT INTO catalog.packages (id, product_id, source, source_key, description, "
                "count, count_unit, last_run_id) VALUES (:id, :p, :s, :k, :d, 20, 'tablet', :r)",
                id=kid,
                p=pid,
                s=self.source,
                k=f"{key}-{i}",
                d=description,
                r=self.run_id,
            )
            for gtin in gtins:
                await self._exec(
                    "INSERT INTO catalog.gtins (gtin, source, package_id, origin, last_run_id) "
                    "VALUES (:g, :s, :p, 'source', :r)",
                    g=gtin,
                    s=self.source,
                    p=kid,
                    r=self.run_id,
                )
        return pid

    async def recall(self, registration_number: str, series: str) -> None:
        await self._exec(
            "INSERT INTO catalog.recall_flags (registration_number, series, reason_code, source) "
            "VALUES (:n, :s, 'quality', 'ru_roszdravnadzor')",
            n=registration_number,
            s=series,
        )

    async def decision(self, gtin: str, status: str, product: uuid.UUID | None = None) -> None:
        await self._exec(
            "INSERT INTO catalog.gtin_link_decisions (gtin, status, product_id, decided_by) "
            "VALUES (:g, :st, :p, 'auto')",
            g=gtin,
            st=status,
            p=product,
        )
