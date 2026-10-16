"""Database layer. Importing the package registers every table on ``Base.metadata``."""

from app.db import models, relatives

__all__ = ["models", "relatives"]
