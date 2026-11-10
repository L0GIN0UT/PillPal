"""Database layer. Importing the package registers every table on ``Base.metadata``."""

from app.db import alerts, consents, entitlements, exports, models, promo, push, relatives

__all__ = [
    "alerts",
    "consents",
    "entitlements",
    "exports",
    "models",
    "promo",
    "push",
    "relatives",
]
