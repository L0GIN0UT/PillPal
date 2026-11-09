"""Ids of source records, one function per level so importers never spell a ``kind`` by hand."""

from __future__ import annotations

from uuid import UUID

from catalog.domain.identity import entity_id


def substance_id(source: str, source_key: str) -> UUID:
    return entity_id(source, "substance", source_key)


def composition_id(source: str, source_key: str) -> UUID:
    return entity_id(source, "composition", source_key)


def product_id(source: str, source_key: str) -> UUID:
    return entity_id(source, "product", source_key)


def package_id(source: str, source_key: str) -> UUID:
    return entity_id(source, "package", source_key)
