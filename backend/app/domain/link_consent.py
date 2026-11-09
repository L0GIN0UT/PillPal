"""Contribution consent for a catalog link (ADR 0014 §2, ADR 0015 §4): pure rules.

The owner's per-link opt-in (``gtin_link_shared``) belongs to one ``(gtin, product)`` pair. It
is reset whenever the pair changes, so a re-link (by anyone, on any device) never carries a
consent given for another package. Only full-access roles (owner, guardian) can give or
withdraw it; a role without full access may re-link but never touches the consent keys.

A *grant* (consent that was not there for this pair) needs ``gtin_link_consent_version`` in the
same mutation: the version is write-only, so a device that echoes old state (``shared=true``,
no version) after a withdrawal or a re-link can never re-grant. An echo for a pair that is
already consented changes nothing.

No IO and no framework imports: callers load the row, pass its state and store the result.
"""

from __future__ import annotations

import uuid
from collections.abc import Collection
from dataclasses import dataclass
from datetime import datetime

from app.domain.gtin import GtinError, normalize


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


def consent_keys_forbidden(full_access: bool, sent: Collection[str]) -> bool:
    """A role without full access sent a consent key: refused whatever the stored value is."""
    return not full_access and bool({"gtin_link_shared", "gtin_link_consent_version"} & set(sent))


def _shareable(gtin14: str) -> bool:
    """Only a valid, non-restricted GTIN may be counted (docs/spec/gtin.md section 3, D3).

    A restricted or mistyped number may still be saved privately on the medication; the check
    applies to a grant only, so withdrawing or keeping an existing consent never depends on it.
    """
    try:
        return normalize(gtin14).classification == "shareable"
    except GtinError:
        return False


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
    contributions_enabled: bool,
    now: datetime,
) -> LinkState:
    """The link state after an upsert that leaves the pair at ``(new_gtin, new_product_id)``.

    ``now`` is the server clock: the consent time is never taken from the client.
    """
    pair_changed = (current.gtin, current.product_id) != (new_gtin, new_product_id)
    if full_access and request.shared is False:
        return _reset(new_gtin, new_product_id)
    if full_access and request.shared is True:
        if current.shared and not pair_changed:
            return current  # an echo (or a replay) for a pair that is already consented
        if request.version is None:
            return _reset(new_gtin, new_product_id)  # not a grant: the rest of the write applies
        if not contributions_enabled:
            raise ConsentError("contributions_disabled")
        if new_gtin is None or new_product_id is None:
            raise ConsentError("gtin_link_needs_gtin_and_product")
        if request.version not in supported_versions:
            raise ConsentError("unsupported_consent_version")
        if not _shareable(new_gtin):
            raise ConsentError("gtin_not_shareable")
        return LinkState(new_gtin, new_product_id, True, request.version, now)
    # Absent: the stored consent stays only while the pair it was given for stays.
    if pair_changed:
        return _reset(new_gtin, new_product_id)
    return current
