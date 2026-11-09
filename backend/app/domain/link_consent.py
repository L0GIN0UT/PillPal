"""Contribution consent for a catalog link (ADR 0014 §2, ADR 0015 §4): pure rules.

The owner's per-link opt-in (``gtin_link_shared``) belongs to one ``(gtin, product)`` pair. It
is reset whenever the pair changes, so a re-link (by anyone, on any device) never carries a
consent given for another package. Only full-access roles (owner, guardian) can give or
withdraw it; an editor may re-link but never carries consent.

No IO and no framework imports: callers load the row, pass its state and store the result.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from dataclasses import dataclass
from datetime import datetime


class ConsentError(Exception):
    """The requested consent is not valid; ``code`` is a stable error code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class LinkState:
    """What a medication stores about its catalog link and the consent for it."""

    gtin: str | None
    product_id: uuid.UUID | None
    shared: bool
    consent_version: int | None
    consented_at: datetime | None


@dataclass(frozen=True)
class ConsentRequest:
    """What the payload says: ``None`` means the key was absent (keep-on-absent)."""

    shared: bool | None
    version: int | None


def flag_change_forbidden(full_access: bool, current: bool, requested: bool | None) -> bool:
    """An upsert of a role without full access that would change the flag."""
    return not full_access and requested is not None and requested != current


def _reset(gtin: str | None, product_id: uuid.UUID | None) -> LinkState:
    return LinkState(gtin, product_id, False, None, None)


def resolve_consent(
    current: LinkState,
    new_gtin: str | None,
    new_product_id: uuid.UUID | None,
    request: ConsentRequest,
    *,
    full_access: bool,
    supported_versions: Collection[int],
    now: datetime,
) -> LinkState:
    """The link state after an upsert that leaves the pair at ``(new_gtin, new_product_id)``.

    ``now`` is the server clock: the consent time is never taken from the client.
    """
    pair_changed = (current.gtin, current.product_id) != (new_gtin, new_product_id)
    if full_access and request.shared is True:
        return _consent(
            current,
            LinkState(new_gtin, new_product_id, False, None, None),
            request.version,
            pair_changed=pair_changed,
            supported=supported_versions,
            now=now,
        )
    if full_access and request.shared is False:
        return _reset(new_gtin, new_product_id)
    # Absent, or sent by a role that cannot consent: the stored consent stays only while the
    # pair it was given for stays.
    if pair_changed:
        return _reset(new_gtin, new_product_id)
    return current


def _consent(
    current: LinkState,
    target: LinkState,
    version: int | None,
    *,
    pair_changed: bool,
    supported: Collection[int],
    now: datetime,
) -> LinkState:
    gtin, product_id = target.gtin, target.product_id
    if gtin is None or product_id is None:
        raise ConsentError("gtin_link_needs_gtin_and_product")
    if current.shared and not pair_changed and version in (None, current.consent_version):
        return current  # the same consent again (an echo or a replay): keep its time
    if version is None:
        raise ConsentError("consent_version_required")
    if version not in supported:
        raise ConsentError("unsupported_consent_version")
    return LinkState(gtin, product_id, True, version, now)
