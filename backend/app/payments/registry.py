"""Which stores exist for this server and their verifiers (ADR 0018 section 6).

Stores per region: RU ``rustore`` and ``app_store``, EU ``app_store`` and ``google_play``;
``Settings`` refuses any other pair at startup. A store of the region that has no working
verifier (RuStore Pay, Google Play, or an unconfigured App Store) gets a stub that answers
``StoreUnavailable``. The settings are read on every call, so a flag flipped in a test takes effect.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from app.config import Settings
from app.domain.payments import APP_STORE, GOOGLE_PLAY, RUSTORE, stores_for
from app.payments.base import PurchaseVerifier
from app.payments.play import GooglePlayVerifier
from app.payments.rustore import RuStoreVerifier, UnavailableVerifier
from app.payments.storekit import StoreKitVerifier

# Apple Root CA - G3, https://www.apple.com/certificateauthority/AppleRootCA-G3.cer (public).
APPLE_ROOT_CERT_PATH = Path(__file__).parent / "certs" / "AppleRootCA-G3.cer"


@lru_cache(maxsize=8)
def _read(path: str) -> bytes:
    return Path(path).read_bytes()


class PaymentRegistry:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        # Fail at startup, not at the first purchase, when a root certificate is unreadable.
        _read(str(APPLE_ROOT_CERT_PATH))
        if settings.payments_apple_root_cert_path is not None:
            _read(settings.payments_apple_root_cert_path)

    @property
    def stores(self) -> list[str]:
        return list(self._settings.payments_stores or stores_for(self._settings.region))

    def get(self, store: str) -> PurchaseVerifier | None:
        """The verifier of ``store``, or ``None`` when this region does not offer it."""
        if store not in self.stores:
            return None
        if store == RUSTORE:
            return RuStoreVerifier()
        if store == GOOGLE_PLAY:
            return GooglePlayVerifier()
        return self._app_store()

    def _app_store(self) -> PurchaseVerifier:
        settings = self._settings
        if settings.payments_apple_bundle_id is None or not settings.payments_products:
            return UnavailableVerifier(APP_STORE)
        root = settings.payments_apple_root_cert_path or str(APPLE_ROOT_CERT_PATH)
        return StoreKitVerifier(
            root_der=_read(root),
            bundle_id=settings.payments_apple_bundle_id,
            products=settings.payments_products,
            allow_sandbox=settings.payments_allow_sandbox,
        )
