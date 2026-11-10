"""Database layer. Importing the package registers every table on ``Base.metadata``."""

from app.db import alerts, consents, models, push, relatives

__all__ = ["alerts", "consents", "models", "push", "relatives"]
