"""National Drug Codes as openFDA prints them: package NDC -> GTIN-14 and best-effort package
counts. The GTIN arithmetic is the shared one (``domain/gtin.py``, docs/spec/gtin.md section 6.2);
this module only recognises the three printed configurations and never guesses.

Risk (docs/phase4-plan.md 4.4): the FDA is moving to a 12-digit NDC. Such values do not match any
configuration here and yield no GTIN rather than a wrong one.
"""

from __future__ import annotations

import re
from decimal import Decimal

from catalog.domain.gtin import ndc_to_gtin14

# Labeler-product-package segment lengths as printed: 4-4-2, 5-3-2 and 5-4-1.
_PACKAGE_NDC = re.compile(r"\d{4}-\d{4}-\d{2}|\d{5}-\d{3}-\d{2}|\d{5}-\d{4}-\d", re.ASCII)
MAX_DESCRIPTION_CHARS = 500
MAX_PACKAGE_COUNT = Decimal(10) ** 9
_NUMBER = r"(\d{1,3}(?:,\d{3})+|\d+)(\.\d+)?"
# "100 TABLET in 1 BOTTLE (12345-678-90)": amount, unit, container; the NDC is dropped.
_SEGMENT = re.compile(
    rf"\s*{_NUMBER}\s+(.+?)\s+in\s+1\s+(.+?)\s*(?:\([^)]*\))?\s*",
    re.IGNORECASE | re.ASCII,
)


def package_gtin14(package_ndc: str) -> str | None:
    """GTIN-14 of a printed package NDC, or ``None`` when it is not one of the three formats."""
    if _PACKAGE_NDC.fullmatch(package_ndc) is None:
        return None
    return ndc_to_gtin14(package_ndc)


def _amount(whole: str, fraction: str | None) -> Decimal:
    return Decimal(whole.replace(",", "") + (fraction or ""))


def package_count(description: str | None) -> tuple[Decimal, str] | None:
    """Count and unit of the innermost units of a package, or ``None`` (best effort).

    ``2 BLISTER PACK in 1 CARTON > 10 TABLET in 1 BLISTER PACK`` is 20 ``tablet``; a chain whose
    levels do not connect, a missing number or an absurd amount gives ``None``.
    """
    if not description or len(description) > MAX_DESCRIPTION_CHARS:
        return None
    total = Decimal(1)
    unit = ""
    container: str | None = None
    for segment in description.split(">"):
        found = _SEGMENT.fullmatch(segment)
        if found is None:
            return None
        whole, fraction, segment_unit, segment_container = found.groups()
        if container is not None and segment_container.casefold() != container:
            return None
        total *= _amount(whole, fraction)
        unit = segment_unit.casefold()
        container = unit
    if not 0 < total < MAX_PACKAGE_COUNT:
        return None
    return total, unit
