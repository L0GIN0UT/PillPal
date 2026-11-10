"""``python -m app.admin promo create|list|disable`` on real PostgreSQL (ADR 0018 section 5)."""

from __future__ import annotations

import re
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.domain.promo import ALPHABET, normalize_promo_code
from tests.conftest import make_settings
from tests.entitlement_helpers import OPERATOR, CliRun, rows, run_cli
from tests.helpers import register
from tests.promo_helpers import KEY_B64, digest_text, insert_code, redeem

pytestmark = pytest.mark.usefixtures("promo_on")

CREATE = (
    "promo",
    "create",
    "--label",
    "autumn-campaign",
    "--kind",
    "ads_removed",
    "--actor",
    "ops-1",
)
LINE = re.compile(r"^(?P<id>[0-9a-f-]{36}) (?P<code>[A-Z2-9-]+)$")


def keyed() -> Settings:
    return make_settings(promo_code_hmac_key=KEY_B64)


async def create(*extra: str, settings: Settings | None = None, label: str | None = None) -> CliRun:
    argv = list(CREATE)
    if label is not None:
        argv[argv.index("--label") + 1] = label
    return await run_cli(*argv, "--max-activations", "5", *extra, settings=settings or keyed())


def printed(result: CliRun) -> list[tuple[uuid.UUID, str]]:
    found = []
    for line in result.out.strip().splitlines():
        match = LINE.match(line)
        assert match, line
        found.append((uuid.UUID(match["id"]), match["code"]))
    return found


async def test_create_prints_one_code_stores_its_digest_and_audits_without_the_code(
    engine: AsyncEngine,
) -> None:
    result = await create("--grant-days", "30")
    assert result.code == 0, result.err
    [(code_id, shown)] = printed(result)
    normalised = normalize_promo_code(shown)
    assert normalised is not None
    assert len(normalised) == 20  # PROMO_CODE_LENGTH
    assert set(normalised) <= set(ALPHABET)
    assert re.fullmatch(r"(\w{4}-){4}\w{4}", shown)  # shown in groups of four

    [row] = await rows(engine, "SELECT * FROM promo_codes")
    assert row["id"] == code_id
    assert row["code_digest"] == digest_text(normalised)
    assert (row["label"], row["kind"], row["grant_days"], row["max_activations"]) == (
        "autumn-campaign",
        "ads_removed",
        30,
        5,
    )
    assert (row["activations"], row["expires_at"], row["disabled_at"]) == (0, None, None)
    [audit] = await rows(engine, "SELECT * FROM admin_audit")
    assert audit["action"] == "promo_create"
    assert audit["object_id"] == code_id  # the id of the code, never the code
    assert audit["target_user_id"] is None
    assert audit["kind"] == "ads_removed"
    assert (audit["actor"], audit["os_user"], audit["host"]) == (
        OPERATOR.actor,
        OPERATOR.os_user,
        OPERATOR.host,
    )
    everything = " ".join(str(v) for v in audit.values())
    assert normalised not in everything
    assert shown not in everything
    assert row["code_digest"] not in everything


async def test_the_codes_are_shown_once_only_in_the_create_output(engine: AsyncEngine) -> None:
    result = await create()
    [(_, shown)] = printed(result)
    listing = await run_cli("promo", "list", settings=keyed())
    assert listing.code == 0, listing.err
    stored = (await rows(engine, "SELECT code_digest FROM promo_codes"))[0]["code_digest"]
    for text in (listing.out, listing.err):
        assert shown not in text
        assert shown.replace("-", "") not in text
        assert stored not in text


async def test_create_with_a_count_prints_distinct_codes_and_one_audit_row_each(
    engine: AsyncEngine,
) -> None:
    result = await create("--count", "3")
    assert result.code == 0, result.err
    codes = printed(result)
    assert len({code for _, code in codes}) == 3
    assert len({code_id for code_id, _ in codes}) == 3
    assert len(await rows(engine, "SELECT id FROM promo_codes")) == 3
    audits = await rows(engine, "SELECT object_id FROM admin_audit WHERE action = 'promo_create'")
    assert {a["object_id"] for a in audits} == {code_id for code_id, _ in codes}


async def test_the_count_is_capped_at_one_hundred(engine: AsyncEngine) -> None:
    for count in ("0", "-1", "101", "many"):
        result = await create("--count", count)
        assert result.code == 2, count
        assert result.out == ""
    assert await rows(engine, "SELECT id FROM promo_codes") == []
    ok = await create("--count", "100")
    assert ok.code == 0, ok.err
    assert len(printed(ok)) == 100


async def test_the_code_length_follows_the_setting(engine: AsyncEngine) -> None:
    result = await create(settings=make_settings(promo_code_hmac_key=KEY_B64, promo_code_length=32))
    [(_, shown)] = printed(result)
    assert len(shown.replace("-", "")) == 32


async def test_create_needs_the_key(engine: AsyncEngine) -> None:
    result = await create(settings=make_settings())
    assert result.code == 2
    assert "PROMO_CODE_HMAC_KEY" in result.err
    assert result.out == ""
    assert await rows(engine, "SELECT id FROM promo_codes") == []


@pytest.mark.parametrize(
    "extra",
    [
        ("--kind", "gold"),
        ("--max-activations", "0"),
        ("--max-activations", "x"),
        ("--grant-days", "0"),
        ("--grant-days", "3651"),
        ("--expires", "2020-01-01T00:00:00+00:00"),  # in the past
        ("--expires", "2099-01-01T00:00:00"),  # no offset
        ("--expires", "tomorrow"),
        ("--actor", "someone@example.com"),
        ("--actor", ""),
    ],
)
async def test_invalid_arguments_exit_two_and_write_nothing(
    engine: AsyncEngine, extra: tuple[str, str]
) -> None:
    argv = [*CREATE, "--max-activations", "5"]
    # A later option overrides an earlier one in argparse.
    result = await run_cli(*argv, *extra, settings=keyed())
    assert result.code == 2
    assert result.out == ""
    assert await rows(engine, "SELECT id FROM promo_codes") == []
    assert await rows(engine, "SELECT id FROM admin_audit") == []


@pytest.mark.parametrize("label", ["", "x" * 65, "ops@example.com", "line\nbreak"])
async def test_a_label_must_be_a_short_printable_campaign_name(
    engine: AsyncEngine, label: str
) -> None:
    result = await create(label=label)
    assert result.code == 2
    assert await rows(engine, "SELECT id FROM promo_codes") == []


async def test_a_label_of_sixty_four_characters_is_accepted(engine: AsyncEngine) -> None:
    result = await create(label="c" * 64)
    assert result.code == 0, result.err


async def test_create_with_an_expiry(engine: AsyncEngine) -> None:
    expires = datetime.now(UTC) + timedelta(days=10)
    result = await create("--expires", expires.isoformat())
    assert result.code == 0, result.err
    [row] = await rows(engine, "SELECT expires_at FROM promo_codes")
    assert row["expires_at"] == expires


async def test_a_failed_batch_prints_nothing_and_stores_nothing(
    engine: AsyncEngine, monkeypatch: pytest.MonkeyPatch
) -> None:
    # Two equal codes violate the unique digest: the whole batch rolls back.
    monkeypatch.setattr("app.admin.promo.generate_code", lambda length: "A" * length)
    result = await create("--count", "2")
    assert result.code == 1
    assert result.out == ""
    assert "IntegrityError" in result.err or "database error" in result.err
    assert "AAAA" not in result.err
    assert await rows(engine, "SELECT id FROM promo_codes") == []
    assert await rows(engine, "SELECT id FROM admin_audit") == []


async def test_a_created_code_can_be_redeemed_through_the_api(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    result = await create("--grant-days", "7")
    [(_, shown)] = printed(result)
    user = await register(client)
    resp = await redeem(client, user, shown)
    assert resp.status_code == 200, resp.text
    assert resp.json()["ads_removed"] is True


async def test_list_shows_metadata_and_the_state_of_each_code(engine: AsyncEngine) -> None:
    now = datetime.now(UTC)
    active = await insert_code(engine, label="campaign-1", max_activations=3, activations=1)
    used = await insert_code(engine, label="campaign-2", max_activations=1, activations=1)
    expired = await insert_code(engine, label="campaign-3", expires_at=now - timedelta(days=1))
    disabled = await insert_code(engine, label="campaign-4", disabled_at=now)
    result = await run_cli("promo", "list", settings=keyed())
    assert result.code == 0, result.err
    by_id = {line.split()[0]: line for line in result.out.strip().splitlines()}
    assert set(by_id) == {str(p.id) for p in (active, used, expired, disabled)}
    assert "active" in by_id[str(active.id)]
    assert "1/3" in by_id[str(active.id)]
    assert "campaign-1" in by_id[str(active.id)]
    assert "exhausted" in by_id[str(used.id)]
    assert "expired" in by_id[str(expired.id)]
    assert "disabled" in by_id[str(disabled.id)]
    for promo in (active, used, expired, disabled):
        assert promo.code not in result.out
        assert digest_text(promo.code) not in result.out


async def test_list_of_nothing_is_empty_and_succeeds(engine: AsyncEngine) -> None:
    result = await run_cli("promo", "list", settings=keyed())
    assert (result.code, result.out) == (0, "")


async def test_list_needs_no_key_and_no_actor(engine: AsyncEngine) -> None:
    await insert_code(engine)
    result = await run_cli("promo", "list", settings=make_settings())
    assert result.code == 0, result.err
    assert await rows(engine, "SELECT id FROM admin_audit") == []  # reading is not audited


async def test_disable_stops_redemption_and_is_audited(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    promo = await insert_code(engine, max_activations=5)
    result = await run_cli("promo", "disable", str(promo.id), "--actor", "ops-1", settings=keyed())
    assert result.code == 0, result.err
    assert str(promo.id) in result.out
    [row] = await rows(engine, "SELECT disabled_at FROM promo_codes")
    assert row["disabled_at"] is not None
    [audit] = await rows(engine, "SELECT * FROM admin_audit")
    assert (audit["action"], audit["object_id"], audit["target_user_id"]) == (
        "promo_disable",
        promo.id,
        None,
    )
    assert audit["kind"] == "ads_removed"
    assert promo.code not in " ".join(str(v) for v in audit.values())
    user = await register(client)
    resp = await redeem(client, user, promo.code)
    assert resp.status_code == 400


async def test_disabling_twice_is_a_no_op(engine: AsyncEngine) -> None:
    promo = await insert_code(engine)
    argv = ("promo", "disable", str(promo.id), "--actor", "ops-1")
    assert (await run_cli(*argv)).code == 0
    first = (await rows(engine, "SELECT disabled_at FROM promo_codes"))[0]["disabled_at"]
    second = await run_cli(*argv)
    assert second.code == 0
    assert "already disabled" in second.out
    assert (await rows(engine, "SELECT disabled_at FROM promo_codes"))[0]["disabled_at"] == first
    assert len(await rows(engine, "SELECT id FROM admin_audit")) == 1


async def test_disabling_an_unknown_or_malformed_id_exits_two(engine: AsyncEngine) -> None:
    unknown = await run_cli("promo", "disable", str(uuid.uuid4()), "--actor", "ops-1")
    assert unknown.code == 2
    assert "no such promo code" in unknown.err
    malformed = await run_cli("promo", "disable", "not-a-uuid", "--actor", "ops-1")
    assert malformed.code == 2
    assert await rows(engine, "SELECT id FROM admin_audit") == []


async def test_the_cli_never_logs_a_code(
    engine: AsyncEngine, capsys: pytest.CaptureFixture[str]
) -> None:
    result = await create("--count", "2")
    codes = [code for _, code in printed(result)]
    logged = capsys.readouterr()
    for code in codes:
        assert code not in logged.out + logged.err
        assert code.replace("-", "") not in logged.out + logged.err
    assert "promo_create" in logged.out  # something was logged: ids and counts only
