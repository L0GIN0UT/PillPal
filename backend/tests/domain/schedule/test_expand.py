from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from app.domain.schedule import (
    Occurrence,
    ScheduleRule,
    expand,
    local_to_utc,
    occurrence_key,
)

SID = "7f1c2d3e-0000-4000-8000-0000000000e2"
DAILY = ScheduleRule.model_validate(
    {
        "v": 1,
        "kind": "daily",
        "start_date": "2026-10-01",
        "times": [
            {"time": "08:00", "dose": {"amount": "1", "unit": "tablet"}},
            {"time": "20:00", "dose": {"amount": "0.5", "unit": "tablet"}},
        ],
    }
)
T0 = datetime(2026, 10, 16, tzinfo=UTC)


def test_occurrence_key_format() -> None:
    assert occurrence_key(SID, date(2026, 10, 16), "08:00") == f"{SID}/2026-10-16T08:00"


def test_occurrence_fields() -> None:
    [first, *_] = expand(
        DAILY, schedule_id=SID, tz="Europe/Samara", start=T0, end=T0 + timedelta(1)
    )
    assert first == Occurrence(
        key=f"{SID}/2026-10-16T08:00",
        local_date=date(2026, 10, 16),
        local_time="08:00",
        at_utc=datetime(2026, 10, 16, 4, 0, tzinfo=UTC),
        dose_amount="1",
        dose_unit="tablet",
    )
    assert first.at_utc.tzinfo is UTC


def test_window_bounds_may_use_any_zone() -> None:
    berlin = ZoneInfo("Europe/Berlin")
    start = datetime(2026, 10, 16, 2, 0, tzinfo=berlin)  # 00:00Z
    end = datetime(2026, 10, 17, 2, 0, tzinfo=berlin)  # 2026-10-17 00:00Z
    in_utc = expand(DAILY, schedule_id=SID, tz="UTC", start=T0, end=T0 + timedelta(days=1))
    assert expand(DAILY, schedule_id=SID, tz="UTC", start=start, end=end) == in_utc


def test_window_spanning_dst_in_same_zone_is_measured_in_real_time() -> None:
    # Bounds given in a DST zone: the 400-day limit applies to elapsed real
    # time, not to the wall-clock difference (here they differ by 1 h).
    berlin = ZoneInfo("Europe/Berlin")
    start = datetime(2026, 10, 1, 12, 0, tzinfo=berlin)  # CEST; end is CET
    end_utc = start.astimezone(UTC) + timedelta(days=400)
    end = end_utc.astimezone(berlin)
    assert expand(DAILY, schedule_id=SID, tz="UTC", start=start, end=end)
    with pytest.raises(ValueError, match="400 days"):
        expand(DAILY, schedule_id=SID, tz="UTC", start=start, end=end + timedelta(seconds=1))


def test_results_are_sorted_by_instant_then_key() -> None:
    occurrences = expand(
        DAILY, schedule_id=SID, tz="Asia/Kathmandu", start=T0, end=T0 + timedelta(days=5)
    )
    pairs = [(o.at_utc, o.key) for o in occurrences]
    assert pairs == sorted(pairs)
    assert len(occurrences) == 10


def test_same_rule_two_zones_same_keys_different_instants() -> None:
    window = {"start": T0, "end": T0 + timedelta(days=3)}
    samara = expand(DAILY, schedule_id=SID, tz="Europe/Samara", **window)
    tokyo = expand(DAILY, schedule_id=SID, tz="Asia/Tokyo", **window)
    common = {o.key for o in samara} & {o.key for o in tokyo}
    assert common
    by_key = {o.key: o.at_utc for o in tokyo}
    for occ in samara:
        if occ.key in common:
            assert by_key[occ.key] - occ.at_utc == timedelta(hours=-5)


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"schedule_id": ""}, "schedule_id"),
        ({"start": datetime(2026, 10, 16)}, "timezone-aware"),
        ({"end": datetime(2026, 10, 17)}, "timezone-aware"),
        ({"end": T0 - timedelta(seconds=1)}, "before start"),
        ({"end": T0 + timedelta(days=400, seconds=1)}, "400 days"),
        ({"tz": "Mars/Olympus_Mons"}, "unknown time zone"),
        ({"tz": ""}, "unknown time zone"),
        ({"tz": "../../etc/passwd"}, "unknown time zone"),
    ],
)
def test_expand_errors(kwargs: dict[str, object], message: str) -> None:
    args: dict[str, object] = {
        "schedule_id": SID,
        "tz": "UTC",
        "start": T0,
        "end": T0 + timedelta(days=1),
    }
    args.update(kwargs)
    with pytest.raises(ValueError, match=message):
        expand(DAILY, **args)  # type: ignore[arg-type]


def test_exactly_400_days_and_empty_window_are_allowed() -> None:
    assert len(expand(DAILY, schedule_id=SID, tz="UTC", start=T0, end=T0 + timedelta(400))) == 800
    assert expand(DAILY, schedule_id=SID, tz="UTC", start=T0, end=T0) == []


def test_open_ended_rule_far_window() -> None:
    start = datetime(2030, 6, 1, tzinfo=UTC)
    occurrences = expand(DAILY, schedule_id=SID, tz="UTC", start=start, end=start + timedelta(1))
    assert [o.key for o in occurrences] == [f"{SID}/2030-06-01T08:00", f"{SID}/2030-06-01T20:00"]


# --- The portable algorithm used by the Dart implementation (spec §3.1) -------


def _offset(zone: ZoneInfo, instant: datetime) -> timedelta:
    offset = instant.replace(tzinfo=UTC).astimezone(zone).utcoffset()
    assert offset is not None
    return offset


def _portable_local_to_utc(wall: datetime, zone: ZoneInfo) -> datetime:
    """Spec §3.1 portable algorithm; ``wall`` is naive. Returns naive UTC."""
    o_before = _offset(zone, wall - timedelta(hours=24))
    o_after = _offset(zone, wall + timedelta(hours=24))
    candidates = [wall - o for o in (o_before, o_after) if _offset(zone, wall - o) == o]
    return min(candidates) if candidates else wall - o_before


@pytest.mark.parametrize(
    "zone_name",
    [
        "Europe/Berlin",
        "America/New_York",
        "America/Sao_Paulo",
        "Australia/Sydney",
        "Australia/Lord_Howe",
        "Pacific/Apia",
        "Pacific/Chatham",
        "Antarctica/Troll",
        "Europe/Dublin",
        "Asia/Tehran",
        "Europe/Moscow",
        "Europe/Samara",
    ],
)
def test_portable_algorithm_matches_zoneinfo(zone_name: str) -> None:
    zone = ZoneInfo(zone_name)
    checked = 0
    probe = datetime(2010, 1, 1)
    previous = _offset(zone, probe)
    while probe < datetime(2031, 1, 1):
        nxt = probe + timedelta(hours=12)
        current = _offset(zone, nxt)
        if current != previous:
            wall = (probe + previous).replace(minute=0) - timedelta(hours=30)
            for step in range(0, 84 * 4):
                local = wall + timedelta(minutes=15 * step)
                expected = local_to_utc(local.date(), local.hour, local.minute, zone).replace(
                    tzinfo=None
                )
                assert _portable_local_to_utc(local, zone) == expected, (zone_name, local)
                checked += 1
            previous = current
        probe = nxt
    assert checked > 0
