"""Service-token matching for the admin and ingest endpoints (milestones 4.5 and 4.7)."""

from __future__ import annotations

import hashlib
import hmac
from collections.abc import Sequence

from catalog.config import TokenEntry


def match_token(presented: str, entries: Sequence[TokenEntry]) -> TokenEntry | None:
    """Return the entry whose SHA-256 digest matches the presented secret, else ``None``.

    Every entry is compared, in constant time each, even after a match, so the time taken does not
    reveal how many entries there are or which one matched.
    """
    digest = hashlib.sha256(presented.encode("utf-8", errors="replace")).hexdigest()
    matched: TokenEntry | None = None
    for entry in entries:
        if hmac.compare_digest(digest, entry.sha256) and matched is None:
            matched = entry
    return matched
