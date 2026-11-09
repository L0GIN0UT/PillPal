"""The ARQ worker: delivery of pushes, the erase job and retention (ADR 0007 §6, ADR 0008 §6,
ADR 0010 §5). Run it with ``arq app.worker.WorkerSettings``.

Jobs are plain ``async def f(ctx)`` functions that delegate to services; ARQ is in
maintenance mode, so nothing here depends on its types beyond this module.

* ``detect_missed_doses`` every minute (the missed-dose detector, ADR 0007), which asks for an
  immediate ``deliver_pushes`` when it queued something (the 10 s cron covers a lost enqueue);
* ``deliver_pushes`` every 10 seconds;
* ``erase_expired_accounts`` hourly (the deletion grace margin assumes this interval, so
  startup refuses a different ``ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS``);
* ``cleanup_retention`` daily;
* ``push_gtin_confirmations`` (ADR 0014 section 3): a cron every minute that does nothing unless
  ``CATALOG_CONTRIBUTIONS_ENABLED`` and ``CATALOG_CONTRIBUTION_INTERVAL_SECONDS`` have passed
  since the last success (the interval is checked against the injected clock, in memory: a
  restart sends once more, which is harmless because every snapshot is complete).

Privacy and security policy for jobs:

* **Jobs take no arguments**, so ARQ's own start-of-job log line carries nothing.
* **Failures are logged by exception type and frames only** (the HTTP middleware policy):
  messages of database and validation errors embed parameters and input. The wrapper turns any
  failure into :class:`JobFailed` raised ``from None``, so ARQ's own failure log (which prints
  the message and the exception chain) never sees the original text either.
* **No results are kept** (``keep_result=0``), and jobs are **JSON**, never pickle: a Redis
  that is reachable by an attacker must not be a code-execution vector. Redis itself needs a
  password (``REDIS_URL=redis://:password@host:6379/0``) and must not be exposed.
* The clock is injectable (``ctx["now"]``), like the dependencies built at startup.
"""

from __future__ import annotations

import asyncio
import json
import traceback
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime, timedelta
from typing import Any, Final, cast

from arq import cron
from arq.connections import RedisSettings
from arq.typing import WorkerCoroutine
from arq.worker import Function, func
from sqlalchemy.ext.asyncio import AsyncEngine

from app.catalog_client import CatalogIngestClient, CatalogUploadError
from app.config import Settings
from app.db.session import create_engine, create_sessionmaker
from app.jobs.account_erasure import erase_expired_accounts
from app.jobs.retention import cleanup_retention
from app.observability import configure_logging, get_logger
from app.push.registry import build_senders, close_senders
from app.services.catalog_contributions import push_gtin_confirmations
from app.services.missed_doses import detect_missed_doses
from app.services.push_delivery import deliver_pending

_log = get_logger("pillpal.worker")

# The deletion margin (``Settings.account_erasure_job_interval_seconds``) assumes this cron.
ERASE_CRON_INTERVAL_SECONDS: Final = 3600
DELIVER_EVERY_SECONDS: Final = 10
JOB_TIMEOUT_SECONDS: Final = 600
MAX_JOBS: Final = 10
HEALTH_CHECK_INTERVAL_SECONDS: Final = 30
# After a failed push the next attempt waits this long (or the interval, if shorter).
CONTRIBUTION_RETRY_SECONDS: Final = 300

Job = Callable[[dict[str, Any]], Awaitable[None]]


class JobFailed(Exception):
    """What ARQ sees of a failed job: its name and the original exception *type* only."""


def _frames(exc: BaseException) -> list[str]:
    return [
        f"{frame.filename}:{frame.lineno}:{frame.name}"
        for frame in traceback.extract_tb(exc.__traceback__)
    ]


def tracked(name: str, job: Job) -> WorkerCoroutine:
    """Wrap a job: failures are logged as type and frames, and re-raised without their text."""

    async def run(ctx: dict[str, Any]) -> None:
        try:
            await job(ctx)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _log.error("job_failed", job=name, exc_type=type(exc).__name__, frames=_frames(exc))
            raise JobFailed(f"{name} failed ({type(exc).__name__})") from None

    run.__name__ = run.__qualname__ = name
    return cast(WorkerCoroutine, run)


# --- JSON job serializer -----------------------------------------------------------------------


def _not_json(_: object) -> object:
    raise TypeError("job data must be plain JSON")


def serialize_job(job: dict[str, Any]) -> bytes:
    return json.dumps(job, separators=(",", ":"), default=_not_json).encode()


def deserialize_job(raw: bytes) -> dict[str, Any]:
    decoded = json.loads(raw)
    if not isinstance(decoded, dict):
        raise ValueError("job data must be a JSON object")
    return decoded


# --- jobs --------------------------------------------------------------------------------------


async def _deliver_pushes(ctx: dict[str, Any]) -> None:
    await deliver_pending(
        ctx["maker"], ctx["settings"], ctx["senders"], ctx["now"], ctx.get("redis")
    )


async def _detect_missed_doses(ctx: dict[str, Any]) -> None:
    if not ctx["settings"].detector_enabled:
        return  # off until the app plans foreign profiles in their own zone (milestone 3.6)
    try:
        report = await detect_missed_doses(ctx["maker"], ctx["settings"], ctx["now"]())
    except Exception:
        # Consecutive failures are the signal an operator alerts on; the wrapper logs type/frames.
        ctx["detector_failures"] = ctx.get("detector_failures", 0) + 1
        _log.error("detector_tick_failed", consecutive_failures=ctx["detector_failures"])
        raise
    ctx["detector_failures"] = 0
    pool = ctx.get("redis")
    if report.pushes and pool is not None:
        try:
            await pool.enqueue_job("deliver_pushes")
        except Exception as exc:  # delivery is best effort here: the 10 s cron picks the rows up
            _log.warning("deliver_enqueue_failed", exc_type=type(exc).__name__)


async def _erase_expired_accounts(ctx: dict[str, Any]) -> None:
    await erase_expired_accounts(ctx["maker"], ctx["settings"], now=ctx["now"]())


async def _cleanup_retention(ctx: dict[str, Any]) -> None:
    await cleanup_retention(ctx["maker"], ctx["settings"], now=ctx["now"]())


async def _push_gtin_confirmations(ctx: dict[str, Any]) -> None:
    settings: Settings = ctx["settings"]
    if not settings.catalog_contributions_enabled:
        return
    now: datetime = ctx["now"]()
    due: datetime | None = ctx.get("contribution_next_at")
    if due is not None and now < due:
        return
    try:
        await push_gtin_confirmations(ctx["maker"], settings, ctx["catalog_client"], now)
    except CatalogUploadError as exc:
        retry = min(settings.catalog_contribution_interval_seconds, CONTRIBUTION_RETRY_SECONDS)
        ctx["contribution_next_at"] = now + timedelta(seconds=retry)
        _log.error("catalog_push_failed", status_code=exc.status_code)  # the status only
        raise
    ctx["contribution_next_at"] = now + timedelta(
        seconds=settings.catalog_contribution_interval_seconds
    )


detect_missed_doses_job = tracked("detect_missed_doses", _detect_missed_doses)
deliver_pushes = tracked("deliver_pushes", _deliver_pushes)
erase_expired_accounts_job = tracked("erase_expired_accounts", _erase_expired_accounts)
cleanup_retention_job = tracked("cleanup_retention", _cleanup_retention)
push_gtin_confirmations_job = tracked("push_gtin_confirmations", _push_gtin_confirmations)


# --- startup and shutdown ----------------------------------------------------------------------


def utc_now() -> datetime:
    return datetime.now(UTC)


async def on_startup(ctx: dict[str, Any]) -> None:
    """Build what the jobs need, unless the caller (tests) injected it into ``ctx``."""
    settings: Settings = ctx.get("settings") or Settings()
    if settings.account_erasure_job_interval_seconds != ERASE_CRON_INTERVAL_SECONDS:
        raise RuntimeError(
            "ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS must equal the erase cron interval "
            f"({ERASE_CRON_INTERVAL_SECONDS}); the deletion deadline margin depends on it"
        )
    configure_logging(settings.log_level)
    ctx["settings"] = settings
    if "maker" not in ctx:
        engine = create_engine(settings)
        ctx["engine"] = engine
        ctx["maker"] = create_sessionmaker(engine)
    if "senders" not in ctx:
        ctx["senders"] = build_senders(settings)
        ctx["owns_senders"] = True
    if settings.catalog_contributions_enabled and "catalog_client" not in ctx:
        ctx["catalog_client"] = CatalogIngestClient(settings)
        ctx["owns_catalog_client"] = True
    ctx.setdefault("now", utc_now)
    _log.info("worker_started", region=settings.region, environment=settings.environment)


async def on_shutdown(ctx: dict[str, Any]) -> None:
    engine: AsyncEngine | None = ctx.get("engine")
    if ctx.get("owns_senders"):
        await close_senders(ctx["senders"])
    if ctx.get("owns_catalog_client"):
        await ctx["catalog_client"].aclose()
    if engine is not None:
        await engine.dispose()
    _log.info("worker_stopped")


# --- ARQ settings ------------------------------------------------------------------------------


def _function(job: WorkerCoroutine) -> Function:
    # keep_result=0: nothing about a finished job stays in Redis; one try (jobs are idempotent
    # and re-run by their cron anyway).
    return func(job, name=job.__qualname__, keep_result=0, timeout=JOB_TIMEOUT_SECONDS, max_tries=1)


def build_redis_settings() -> RedisSettings:
    """ARQ's connection, from the same ``REDIS_URL`` setting the API uses (one source)."""
    return RedisSettings.from_dsn(Settings().redis_url)


class WorkerSettings:
    functions = [  # noqa: RUF012 - ARQ reads plain class attributes
        _function(detect_missed_doses_job),
        _function(deliver_pushes),
        _function(erase_expired_accounts_job),
        _function(cleanup_retention_job),
        _function(push_gtin_confirmations_job),
    ]
    cron_jobs = [  # noqa: RUF012
        cron(
            detect_missed_doses_job,
            name="detect_missed_doses",
            second=0,
            timeout=JOB_TIMEOUT_SECONDS,
            keep_result=0,
        ),
        cron(
            deliver_pushes,
            name="deliver_pushes",
            second=set(range(0, 60, DELIVER_EVERY_SECONDS)),
            timeout=JOB_TIMEOUT_SECONDS,
            keep_result=0,
        ),
        cron(
            erase_expired_accounts_job,
            name="erase_expired_accounts",
            minute=5,
            second=0,
            timeout=JOB_TIMEOUT_SECONDS,
            keep_result=0,
        ),
        cron(
            cleanup_retention_job,
            name="cleanup_retention",
            hour=3,
            minute=15,
            second=0,
            timeout=JOB_TIMEOUT_SECONDS,
            keep_result=0,
        ),
        cron(
            push_gtin_confirmations_job,
            name="push_gtin_confirmations",
            second=0,
            timeout=JOB_TIMEOUT_SECONDS,
            keep_result=0,
        ),
    ]
    on_startup = on_startup
    on_shutdown = on_shutdown
    job_serializer = serialize_job
    job_deserializer = deserialize_job
    redis_settings = build_redis_settings()
    keep_result = 0
    keep_result_forever = False
    log_results = False
    max_jobs = MAX_JOBS
    job_timeout = JOB_TIMEOUT_SECONDS
    max_tries = 1
    health_check_interval = HEALTH_CHECK_INTERVAL_SECONDS
