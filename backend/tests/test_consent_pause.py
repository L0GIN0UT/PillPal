"""The server pauses a profile while nobody consented to health data (ADR 0016 s.5).

Owner decisions of 2026-11-11: only a *missing* consent pauses (never recorded or withdrawn; a new
text version does not), and any full-access guardian's consent keeps a managed profile running.
This file covers the definition, the detector and the pushes; ``test_consent_pause_access.py``
the relative-facing paths, the limits and the catalog.
"""

from __future__ import annotations

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.services import consent_pause
from tests.conftest import FakeClock
from tests.consent_pause_helpers import (
    Maker,
    count_statements,
    missing_of,
    paused_profiles,
    reaccept,
    set_accepted_at,
    withdraw_health,
)
from tests.detector_helpers import (
    World,
    alert_rows,
    at,
    check_window,
    make_world,
    missed_pushes,
    register_token,
    set_watermark,
    tick,
)
from tests.helpers import create_medication, link_accounts, register
from tests.push_outbox_helpers import deliver, fake_senders, insert_outbox, outbox_rows

# --- the definition -----------------------------------------------------------------------------


@pytest.mark.parametrize("how", ["withdrawn", "never_recorded"])
async def test_a_missing_consent_pauses_the_profile(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, how: str
) -> None:
    user = await register(client)
    assert await paused_profiles(maker, user.self_profile_id) == set()

    if how == "withdrawn":
        await withdraw_health(engine, user)
    else:
        async with engine.begin() as conn:
            await conn.execute(text("DELETE FROM consents WHERE user_id = :u"), {"u": user.id})

    assert await paused_profiles(maker, user.self_profile_id) == {user.self_profile_id}
    assert "health_data" in await missing_of(client, user)
    await reaccept(client, user)
    assert await paused_profiles(maker, user.self_profile_id) == set()


async def test_an_outdated_version_does_not_pause(
    client: AsyncClient,
    maker: Maker,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Owner decision A: processing continues under the previous consent until the user
    accepts the new text; the client gate alone asks for it."""
    user = await register(client)
    monkeypatch.setattr(settings, "consent_versions_health_data", [1, 2])
    assert "health_data" in await missing_of(client, user)  # the app shows its gate
    assert await paused_profiles(maker, user.self_profile_id) == set()


async def test_a_never_recorded_account_is_paused_while_registration_is_optional(
    client: AsyncClient, maker: Maker, settings: Settings
) -> None:
    """Field-test accounts have no records (the flag is off): the pause applies to them too."""
    assert settings.consent_required_at_registration is False
    user = await register(client, consents=False)
    assert await paused_profiles(maker, user.self_profile_id) == {user.self_profile_id}


async def test_the_pause_can_be_switched_off(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    world = await make_world(client, engine)
    await withdraw_health(engine, world.owner)
    # The module keeps the settings of the app created last (another test app may have been).
    monkeypatch.setattr(consent_pause, "_settings", settings)
    monkeypatch.setattr(settings, "consent_server_pause_enabled", False)
    assert await paused_profiles(maker, world.profile_id) == set()
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 1


async def test_only_health_data_pauses_not_terms_or_privacy(
    client: AsyncClient, engine: AsyncEngine, maker: Maker
) -> None:
    user = await register(client)
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE consents SET withdrawn_at = now() "
                "WHERE user_id = :u AND kind <> 'health_data'"
            ),
            {"u": user.id},
        )
    assert await missing_of(client, user) == ["terms", "privacy"]
    assert await paused_profiles(maker, user.self_profile_id) == set()


# --- the missed-dose detector -------------------------------------------------------------------


async def test_the_detector_skips_a_paused_owner_and_sends_nothing(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await withdraw_health(engine, world.owner)

    report = await check_window(maker, engine, settings, at(8, 30))

    assert (report.alerts, report.pushes, report.profiles) == (0, 0, 0)
    assert await alert_rows(engine) == []
    assert await missed_pushes(engine) == []


async def test_the_detector_resumes_when_the_consent_is_accepted_again(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, times=("08:00", "09:00"))
    await withdraw_health(engine, world.owner)
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0

    await reaccept(client, world.owner)
    await set_accepted_at(engine, world.owner, at(9, 0))
    report = await check_window(maker, engine, settings, at(9, 30))

    assert report.alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.occurrence_key == world.key("09:00")  # the paused 08:00 is not made up later
    assert len(await missed_pushes(engine)) == 1


async def test_the_tick_in_which_a_consent_returns_is_skipped(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    """No false alert for a dose that fell due while the app was not syncing."""
    world = await make_world(client, engine, times=("08:00", "09:00"))
    await withdraw_health(engine, world.owner)
    await reaccept(client, world.owner)
    await set_accepted_at(engine, world.owner, at(8, 30))  # inside [08:25, 08:35)

    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 0
    assert (await check_window(maker, engine, settings, at(9, 30))).alerts == 1
    [alert] = await alert_rows(engine)
    assert alert.occurrence_key == world.key("09:00")


async def test_a_paused_owner_does_not_hide_other_owners_alerts(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    paused_world = await make_world(client, engine)
    live_world = await make_world(client, engine)
    await withdraw_health(engine, paused_world.owner)

    report = await check_window(maker, engine, settings, at(8, 30))

    assert report.alerts == 1
    [alert] = await alert_rows(engine)
    assert str(alert.profile_id) == live_world.profile_id


async def test_a_consented_co_guardian_keeps_the_missed_dose_alerts_of_a_managed_profile(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    """Owner decision B: one consenting guardian is enough; none left means paused."""
    world = await make_world(client, engine, managed=True, relatives=("guardian", "viewer"))
    await withdraw_health(engine, world.owner)
    assert await paused_profiles(maker, world.profile_id) == set()
    assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 1

    await withdraw_health(engine, world.relatives["guardian"])
    assert await paused_profiles(maker, world.profile_id) == {world.profile_id}
    await set_watermark(engine, at(8, 25, day=18))
    assert (await tick(maker, settings, at(8, 35, day=18))).alerts == 0


async def test_the_detector_batch_has_no_per_profile_queries(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    async def build(count: int, pause: int) -> list[World]:
        worlds = [await make_world(client, engine, times=("08:00", "09:00")) for _ in range(count)]
        for world in worlds[:pause]:
            await withdraw_health(engine, world.owner)
        return worlds

    await build(2, 1)
    with count_statements(engine) as small:
        assert (await check_window(maker, engine, settings, at(8, 30))).alerts == 1

    await build(4, 2)
    with count_statements(engine) as large:
        # Two more live profiles, three alerts instead of one: the same number of statements.
        assert (await check_window(maker, engine, settings, at(9, 30))).alerts == 3
    assert len(large) == len(small)


# --- queued pushes ------------------------------------------------------------------------------


async def test_queued_missed_pushes_are_dropped_while_paused_and_sent_after_resume(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    now: FakeClock,
) -> None:
    owner, viewer = await register(client), await register(client)
    medication = await create_medication(client, owner)
    await link_accounts(client, owner, viewer, "viewer")
    for user in (owner, viewer):
        await register_token(client, user, "phone")  # one token per account
    queued = [
        await insert_outbox(engine, user, owner.self_profile_id, medication_id=medication["id"])
        for user in (owner, viewer)
    ]
    await withdraw_health(engine, owner)

    report = await deliver(maker, settings, fake_senders(), now)

    assert (report.sent, report.dropped) == (0, 2)
    states = {r.id: (r.status, r.last_error_code) for r in await outbox_rows(engine)}
    assert set(states) == set(queued)
    assert set(states.values()) == {("dropped", "access_changed")}

    await reaccept(client, owner)
    again = [
        await insert_outbox(engine, user, owner.self_profile_id, medication_id=medication["id"])
        for user in (owner, viewer)
    ]
    resumed = await deliver(maker, settings, fake_senders(), now)
    assert (resumed.sent, resumed.dropped) == (2, 0)
    states = {r.id: r.status for r in await outbox_rows(engine)}
    assert [states[i] for i in again] == ["sent", "sent"]


async def test_a_resolved_push_still_reaches_a_paused_owner(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    now: FakeClock,
) -> None:
    """``resolved`` only withdraws an earlier alert, so it is never held back."""
    owner = await register(client)
    medication = await create_medication(client, owner)
    await register_token(client, owner, "phone")
    row = await insert_outbox(
        engine, owner, owner.self_profile_id, medication_id=medication["id"], kind="resolved"
    )
    await withdraw_health(engine, owner)

    report = await deliver(maker, settings, fake_senders(), now)

    assert (report.sent, report.dropped) == (1, 0)
    assert {r.id: r.status for r in await outbox_rows(engine)}[row] == "sent"


async def test_a_link_notice_is_dropped_while_its_grant_is_paused(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    now: FakeClock,
) -> None:
    owner, viewer = await register(client), await register(client)
    grant = await link_accounts(client, owner, viewer, "viewer")
    await register_token(client, owner, "phone")
    row = await insert_outbox(
        engine, owner, owner.self_profile_id, kind="link_accepted", grant_id=grant["id"]
    )
    await withdraw_health(engine, owner)

    report = await deliver(maker, settings, fake_senders(), now)

    assert (report.sent, report.dropped) == (0, 1)
    states = {r.id: (r.status, r.last_error_code) for r in await outbox_rows(engine)}
    assert states[row] == ("dropped", "access_changed")
