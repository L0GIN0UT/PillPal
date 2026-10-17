"""Settings of the missed-dose detector (ADR 0007), a mixin of ``app.config.Settings``."""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings


class DetectorSettings(BaseSettings):
    # Off until the app plans managed and foreign profiles in ``profiles.timezone`` (milestone
    # 3.6, decision D4): before that, the server would alert on instants the apps do not remind at.
    detector_enabled: bool = False
    # One tick looks at a window of at most this long ...
    detector_max_window_seconds: int = Field(default=600, ge=60)
    # ... and after longer downtime skips ahead to this far behind now (and does not alert for
    # late undos of occurrences older than this).
    detector_max_catchup_seconds: int = Field(default=6 * 3600, ge=60)
    # Owners of a batch are locked in one transaction: advisory locks live in the shared lock
    # table (``max_locks_per_transaction``), so the batch is bounded (README, ADR 0007).
    detector_profile_batch: int = Field(default=500, ge=1, le=1000)
    # A batch that cannot get its journal locks this long fails the tick; the window replays.
    detector_lock_timeout_ms: int = Field(default=5000, ge=100)
    # Undos are read this far before the window: ``recorded_at`` is the writer's clock.
    detector_skew_margin_seconds: int = Field(default=120, ge=0)
    # Alerts only serve dedupe and ``resolved``: catch-up plus push staleness never need more.
    detector_alert_retention_hours: int = Field(default=72, ge=1)
