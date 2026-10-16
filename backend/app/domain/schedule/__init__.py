"""Schedule engine: rule validation and occurrence expansion.

Specification: docs/spec/schedule.md. Shared vectors: spec/schedule-vectors/.
"""

from app.domain.schedule.engine import (
    MAX_WINDOW,
    Occurrence,
    expand,
    load_zone,
    local_to_utc,
    occurrence_key,
)
from app.domain.schedule.rule import (
    Dose,
    DoseUnit,
    RuleKind,
    ScheduleRule,
    TimeSlot,
    normalize_amount,
)

__all__ = [
    "MAX_WINDOW",
    "Dose",
    "DoseUnit",
    "Occurrence",
    "RuleKind",
    "ScheduleRule",
    "TimeSlot",
    "expand",
    "load_zone",
    "local_to_utc",
    "normalize_amount",
    "occurrence_key",
]
