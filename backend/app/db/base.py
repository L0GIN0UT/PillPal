"""Declarative base with a deterministic constraint naming convention."""

from __future__ import annotations

from datetime import datetime
from typing import Any

from sqlalchemy import DateTime, MetaData
from sqlalchemy.orm import DeclarativeBase

NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)
    type_annotation_map: dict[Any, Any] = {datetime: DateTime(timezone=True)}  # noqa: RUF012


def sql_in(column: str, values: tuple[str, ...]) -> str:
    """``column IN ('a', 'b')`` for CHECK constraints on enum-like text columns."""
    return f"{column} IN ({', '.join(repr(v) for v in values)})"
