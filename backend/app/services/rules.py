"""Schedule rule validation via the shared schedule engine (app.domain.schedule)."""

from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from app.domain.schedule import ScheduleRule
from app.errors import request_validation_error


def canonical_rule(data: Any) -> dict[str, Any]:
    """Validate ``data`` as rule v1 and return its canonical JSON form.

    Raises ``pydantic.ValidationError`` for an invalid rule.
    """
    return ScheduleRule.model_validate(data).to_json()


def canonical_rule_or_422(data: Any, loc: tuple[str, ...] = ("body", "rule")) -> dict[str, Any]:
    try:
        return canonical_rule(data)
    except ValidationError as exc:
        raise request_validation_error(exc, loc) from None
