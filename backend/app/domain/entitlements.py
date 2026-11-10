"""Entitlements: kinds, sources and the effective-state rule (ADR 0018 sections 1 and 2).

Pure: rows are anything with ``kind``, ``expires_at`` and ``revoked_at``. A kind is effective
when at least one row of that kind is not revoked and has not expired; the expiry instant itself
is already expired (``now < expires_at``). Rows are never deleted to revoke.
"""

from __future__ import annotations

from collections.abc import Iterable
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

ADS_REMOVED = "ads_removed"
LIMITS_LIFTED = "limits_lifted"
ENTITLEMENT_KINDS = (ADS_REMOVED, LIMITS_LIFTED)
ENTITLEMENT_SOURCES = ("purchase", "promo", "admin_grant")


class EntitlementRow(Protocol):
    @property
    def kind(self) -> str: ...
    @property
    def expires_at(self) -> datetime | None: ...
    @property
    def revoked_at(self) -> datetime | None: ...


@dataclass(frozen=True)
class Effective:
    ads_removed: bool
    limits_lifted: bool


def is_active(row: EntitlementRow, now: datetime) -> bool:
    """Not revoked (whenever) and not yet expired."""
    return row.revoked_at is None and (row.expires_at is None or now < row.expires_at)


def effective(rows: Iterable[EntitlementRow], now: datetime) -> Effective:
    active = {row.kind for row in rows if is_active(row, now)}
    return Effective(ads_removed=ADS_REMOVED in active, limits_lifted=LIMITS_LIFTED in active)
