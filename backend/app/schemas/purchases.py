"""``POST /v1/me/purchases`` (ADR 0018 section 6)."""

from __future__ import annotations

from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.domain.payments import APP_STORE

# The widest body the limit setting allows (``PAYMENTS_MAX_BODY_BYTES``); the middleware enforces
# the configured one before the body is parsed.
MAX_PROOF_LENGTH = 64 * 1024


class PurchaseIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    store: Literal["app_store", "rustore", "google_play"]
    # The proof lives under these names only (log and error-tracker scrubbers filter them by
    # name), is never echoed in an error and never stored.
    signed_transaction: str | None = Field(
        default=None, min_length=1, max_length=MAX_PROOF_LENGTH, repr=False
    )
    purchase_token: str | None = Field(
        default=None, min_length=1, max_length=MAX_PROOF_LENGTH, repr=False
    )

    @model_validator(mode="after")
    def _the_proof_matches_the_store(self) -> Self:
        # StoreKit hands over a signed transaction; RuStore Pay and Google Play a purchase token.
        wanted, other = (
            (self.signed_transaction, self.purchase_token)
            if self.store == APP_STORE
            else (self.purchase_token, self.signed_transaction)
        )
        if wanted is None or other is not None:
            raise ValueError("the proof does not match the store")
        return self

    @property
    def proof(self) -> str:
        return self.signed_transaction or self.purchase_token or ""
