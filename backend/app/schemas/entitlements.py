"""``GET /v1/me/entitlements`` (ADR 0018 section 2)."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict

EntitlementKind = Literal["ads_removed", "limits_lifted"]
EntitlementSource = Literal["purchase", "promo", "admin_grant"]


class EntitlementOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    kind: EntitlementKind
    source: EntitlementSource
    granted_at: datetime
    expires_at: datetime | None


class EntitlementsOut(BaseModel):
    ads_removed: bool
    limits_lifted: bool
    # The entitlements in force at ``server_time`` (not revoked, not expired).
    items: list[EntitlementOut]
    server_time: datetime
    # What the app passes to the store at purchase (StoreKit ``appAccountToken``): a keyed
    # pseudonym of the account (ADR 0018 section 6). ``null`` while payments are not configured.
    app_account_token: uuid.UUID | None = None
