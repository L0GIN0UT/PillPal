"""RuStore Pay verifier: a stub until the developer has a RuStore account (ADR 0018 section 6).

Every call answers ``StoreUnavailable`` (503 ``store_unavailable``); nothing is accepted on trust.
"""

from __future__ import annotations

import uuid
from datetime import datetime

from app.domain.payments import RUSTORE
from app.payments.base import StoreUnavailable, VerifiedPurchase


class UnavailableVerifier:
    """A store without a working verifier."""

    def __init__(self, store: str) -> None:
        self.store = store

    def verify(self, proof: str, *, account_token: uuid.UUID, now: datetime) -> VerifiedPurchase:
        raise StoreUnavailable


class RuStoreVerifier(UnavailableVerifier):
    def __init__(self) -> None:
        super().__init__(RUSTORE)
