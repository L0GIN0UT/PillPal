"""Promo codes in the personal-data inventory and the log and error-tracker rules."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.domain.promo import group_code
from app.observability import (
    SENSITIVE_KEYS,
    SENTRY_SECRET_KEYS,
    redact_sensitive,
    scrub_sentry_event,
)
from app.services.export_archive import exported_columns
from app.services.personal_data import TABLE_CLASSIFICATION
from tests.grace_helpers import count, delete_and_erase
from tests.helpers import register
from tests.promo_helpers import UNKNOWN_CODE, activations_of, digest_text, insert_code, redeem
from tests.test_export_archive import archive_of, text_of

# --- the inventory ------------------------------------------------------------------------------


def test_the_codes_table_is_system_and_the_redemptions_are_personal_and_exported() -> None:
    codes = TABLE_CLASSIFICATION["promo_codes"]
    redemptions = TABLE_CLASSIFICATION["promo_redemptions"]
    assert (codes.kind, codes.owner_column, codes.export) == ("system", None, "none")
    assert codes.export_reason
    assert (redemptions.kind, redemptions.owner_column, redemptions.owner_ref) == (
        "personal",
        "user_id",
        "user",
    )
    assert redemptions.export == "rows"
    assert set(exported_columns("promo_redemptions")) == {
        "code_id",
        "user_id",
        "redeemed_at",
        "entitlement_id",
    }


# --- erasure and export -------------------------------------------------------------------------


@pytest.mark.usefixtures("promo_on")
async def test_erasing_an_account_deletes_its_redemptions_and_keeps_the_code(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    gone, kept = await register(client), await register(client)
    promo = await insert_code(engine, max_activations=5)
    assert (await redeem(client, gone, promo.code)).status_code == 200
    assert (await redeem(client, kept, promo.code)).status_code == 200

    await delete_and_erase(client, gone)

    assert await count(engine, "promo_redemptions", "user_id = :u", u=uuid.UUID(gone.id)) == 0
    assert await count(engine, "promo_redemptions", "user_id = :u", u=uuid.UUID(kept.id)) == 1
    assert await count(engine, "entitlements", "user_id = :u", u=uuid.UUID(gone.id)) == 0
    assert await count(engine, "entitlements", "user_id = :u", u=uuid.UUID(kept.id)) == 1
    # The code is shared by every account: it stays, and the activation is not given back.
    assert await count(engine, "promo_codes", "id = :c", c=promo.id) == 1
    assert await activations_of(engine, promo) == 2


@pytest.mark.usefixtures("promo_on")
async def test_the_export_holds_the_accounts_redemptions_and_never_a_code_or_digest(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    me, other = await register(client), await register(client)
    promo = await insert_code(engine, max_activations=5)
    assert (await redeem(client, me, promo.code)).status_code == 200
    assert (await redeem(client, other, promo.code)).status_code == 200

    _, members = await archive_of(client, me)
    text = text_of(members)

    [row] = members["tables/promo_redemptions.json"]
    assert row["user_id"] == me.id
    assert row["code_id"] == str(promo.id)
    assert set(row) == {"code_id", "user_id", "redeemed_at", "entitlement_id"}
    assert "tables/promo_codes.json" not in members
    assert other.id not in text
    for needle in (promo.code, group_code(promo.code), digest_text(promo.code)):
        assert needle not in text
    assert members["manifest.json"]["tables"]["promo_redemptions"] == 1


# --- logs and the error tracker -----------------------------------------------------------------


@pytest.mark.usefixtures("promo_on")
async def test_a_code_never_reaches_the_logs_on_any_outcome(
    client: AsyncClient, engine: AsyncEngine, capsys: pytest.CaptureFixture[str]
) -> None:
    user, replayer = await register(client), await register(client)
    good = await insert_code(engine, max_activations=5)
    used = await insert_code(engine, max_activations=1, activations=1)
    forms = [
        good.code,
        group_code(good.code),
        good.code.lower(),
        used.code,
        UNKNOWN_CODE,
        "SYNTHETIC-0-INVALID-CODE-0",
    ]
    for form in forms:
        await redeem(client, user, form)  # success, replays, rejections
    await redeem(client, replayer, good.code)
    await client.post(
        "/v1/me/promo/redeem",
        json={"code": good.code, "extra": 1},
        headers=user.headers,
    )  # a 422
    logged = capsys.readouterr()
    output = logged.out + logged.err
    assert "http_request" in output  # the access log ran
    for secret in (good.code, used.code, UNKNOWN_CODE, "SYNTHETIC-0-INVALID-CODE-0"):
        assert secret not in output
        assert group_code(secret) not in output
        assert secret.lower() not in output
    assert digest_text(good.code) not in output
    assert digest_text(used.code) not in output


@pytest.mark.usefixtures("promo_on")
async def test_error_bodies_never_echo_the_code(client: AsyncClient) -> None:
    user = await register(client)
    resp = await redeem(client, user, UNKNOWN_CODE)
    assert resp.status_code == 400
    assert UNKNOWN_CODE not in resp.text
    assert resp.json()["error"].keys() == {"code", "message"}


def test_promo_code_is_a_redacted_log_key_and_a_scrubbed_tracker_key() -> None:
    assert "promo_code" in SENSITIVE_KEYS
    assert "promo_code" in SENTRY_SECRET_KEYS
    logged = redact_sensitive(None, "info", {"event": "x", "promo_code": "SYNTHETIC-CODE"})
    assert logged["promo_code"] == "[redacted]"


def test_the_error_tracker_loses_a_code_in_a_request_body_and_in_frame_variables() -> None:
    event: dict[str, Any] = {
        "request": {"data": {"code": "BODYCODE22", "keep": "ok"}},
        "extra": {"promo_code": "EXTRACODE22", "error": {"code": "invalid_promo_code"}},
        "breadcrumbs": {"values": [{"data": {"promo_code": "CRUMBCODE22"}}]},
        "exception": {
            "values": [
                {
                    "stacktrace": {
                        "frames": [{"vars": {"promo_code": "FRAMECODE22", "code": "FRAMEBODY22"}}]
                    }
                }
            ]
        },
    }
    scrubbed = scrub_sentry_event(event, {})
    assert scrubbed is not None
    dumped = str(scrubbed)
    for secret in ("BODYCODE22", "EXTRACODE22", "CRUMBCODE22", "FRAMECODE22", "FRAMEBODY22"):
        assert secret not in dumped
    assert scrubbed["extra"]["error"]["code"] == "invalid_promo_code"  # the error code stays
    assert scrubbed["request"]["data"]["keep"] == "ok"


class _BrokenSession:
    """Stands in for the database session: the first query raises."""

    async def scalar(self, *args: Any, **kwargs: Any) -> Any:
        raise RuntimeError("synthetic failure")


def _frames_of(exc: BaseException) -> list[dict[str, Any]]:
    """What an error tracker captures: the locals of every application frame of the traceback."""
    frames: list[dict[str, Any]] = []
    tb = exc.__traceback__
    while tb is not None:
        if str(tb.tb_frame.f_globals.get("__name__", "")).startswith("app."):  # not the test
            frames.append({"vars": dict(tb.tb_frame.f_locals)})
        tb = tb.tb_next
    return frames


async def test_an_error_inside_redeem_code_does_not_leave_the_code_in_a_tracker_event() -> None:
    from datetime import UTC, datetime

    from app.services.promo import redeem_code
    from tests.promo_helpers import KEY

    typed = group_code(UNKNOWN_CODE).lower()
    with pytest.raises(RuntimeError) as caught:
        await redeem_code(
            _BrokenSession(),  # type: ignore[arg-type]
            uuid.uuid4(),
            typed,
            KEY,
            datetime.now(UTC),
        )
    frames = _frames_of(caught.value)
    assert any("promo_code" in frame["vars"] for frame in frames)  # the frame does hold it
    event = {"exception": {"values": [{"stacktrace": {"frames": frames}}]}}

    scrubbed = scrub_sentry_event(event, {})

    assert scrubbed is not None
    dumped = str(scrubbed)
    for form in (typed, UNKNOWN_CODE, UNKNOWN_CODE.lower(), group_code(UNKNOWN_CODE)):
        assert form not in dumped
