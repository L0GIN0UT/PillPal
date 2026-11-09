"""What a medication tombstone erases, and the CHECKs of the catalog references (ADR 0015 §4).

Plain constants, no SQLAlchemy: the ORM model builds its constraints from them, and a test
compares what migrations 0014 and 0015 create with what the model declares.
"""

from __future__ import annotations

from app.limits import MANUAL_INGREDIENTS_MAX

# Content erased from tombstones (privacy: no medical data outlives a delete).
MEDICATION_CONTENT = (
    "name",
    "form",
    "strength_text",
    "notes",
    "stock_count",
    "stock_unit",
    "low_stock_days",
    "stock_set_at",
    # Catalog references (ADR 0015 §4): what the owner takes is medical data.
    "catalog_product_id",
    "catalog_package_id",
    "catalog_composition_id",
    "gtin",
    "manual_ingredients",
)
# The owner's contribution consent record. Not content (never projected), but a tombstone
# keeps none of it; ``gtin_link_shared`` is reset to false next to it.
MEDICATION_CONSENT = ("gtin_link_consent_version", "gtin_link_consented_at")
MEDICATION_ERASED = (*MEDICATION_CONTENT, *MEDICATION_CONSENT)

# CHECKs added by migrations 0014 and 0015, by constraint name.
CATALOG_CHECKS = {
    "gtin_format": "gtin IS NULL OR gtin ~ '^[0-9]{14}$'",
    "gtin_link_needs_refs": (
        "NOT gtin_link_shared OR (gtin IS NOT NULL AND catalog_product_id IS NOT NULL)"
    ),
    "gtin_link_live": "deleted_at IS NULL OR NOT gtin_link_shared",
    "gtin_link_consent_pair": (
        "(gtin_link_shared AND gtin_link_consent_version IS NOT NULL "
        "AND gtin_link_consented_at IS NOT NULL) "
        "OR (NOT gtin_link_shared AND gtin_link_consent_version IS NULL "
        "AND gtin_link_consented_at IS NULL)"
    ),
    "manual_ingredients": (
        "manual_ingredients IS NULL OR (jsonb_typeof(manual_ingredients) = 'array' "
        f"AND jsonb_array_length(manual_ingredients) <= {MANUAL_INGREDIENTS_MAX})"
    ),
}
