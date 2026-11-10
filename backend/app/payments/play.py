"""Google Play verifier: a stub until the developer has a Play Console account (ADR 0018 section 6).

Every call answers ``StoreUnavailable`` (503 ``store_unavailable``); nothing is accepted on trust.
"""

from __future__ import annotations

from app.domain.payments import GOOGLE_PLAY
from app.payments.rustore import UnavailableVerifier


class GooglePlayVerifier(UnavailableVerifier):
    def __init__(self) -> None:
        super().__init__(GOOGLE_PLAY)
