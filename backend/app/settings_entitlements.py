"""Settings of entitlements and the admin audit (ADR 0018), a mixin of ``app.config.Settings``."""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings


class EntitlementSettings(BaseSettings):
    # Audit rows older than this are deleted by the daily retention job.
    admin_audit_retention_days: int = Field(default=365, ge=1)
