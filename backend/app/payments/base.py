"""The verifier protocol of a payment store (ADR 0018 section 6).

A verifier turns what the client hands over (a StoreKit JWS, a purchase token) into a
``VerifiedPurchase`` or raises. ``original_transaction_id`` is the generic stable purchase
identifier: each store's verifier maps its own into it. The proof itself is never stored, logged
or kept in an exception.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol


class InvalidPurchase(Exception):
    """The proof is not a valid purchase of this account.

    ``reason`` is a fixed code for logs and tests (never client input); the client always gets the
    same answer, ``invalid_purchase``.
    """

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class StoreUnavailable(Exception):
    """The store has no working verifier yet (stubs) or is not configured."""


@dataclass(frozen=True)
class VerifiedPurchase:
    store: str
    product_id: str
    # The kind of the product in ``PAYMENTS_PRODUCTS`` (``remove_ads``): what it grants.
    product_kind: str
    original_transaction_id: str
    environment: str  # production | sandbox
    purchased_at: datetime


class PurchaseVerifier(Protocol):
    store: str

    def verify(self, proof: str, *, account_token: uuid.UUID, now: datetime) -> VerifiedPurchase:
        """Check ``proof`` for the account owning ``account_token``; CPU bound, no network."""
        ...
