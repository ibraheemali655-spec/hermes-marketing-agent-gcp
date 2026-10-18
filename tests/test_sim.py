from datetime import date, datetime, timedelta

import pytest

from hermes_gcp import sim
from hermes_gcp.sim import TZ, fires, idle_shutdown

START = date(2026, 5, 18)


def t(h, m=0, day=19):
    return datetime(2026, 5, day, h, m, tzinfo=TZ)


def test_campaign_is_tue_thu_sat():
    slots = sim.campaign_slots(START, 10)
    assert len(slots) == 30
    assert {s.weekday() for _, s in slots} == {1, 3, 5}


@pytest.mark.parametrize("up, expected", [
    ([(t(8), t(12))], True),                    # up at the slot
    ([(t(10, 59), t(12))], True),               # comes up inside the 2 h grace
    ([(t(11, 1), t(12))], False),               # too late: fast-forwarded, never caught up
    ([(t(6), t(8, 59))], False),                # went down just before the slot
    ([], False),
])
def test_hermes_grace_semantics(up, expected):
    assert fires(t(9), up) is expected


def test_watchdog_stops_30_to_35_minutes_after_activity():
    booted = t(8, 52)
    for end in (t(9, 3), t(9, 10), t(10, 41)):
        idle = idle_shutdown(end, booted) - end
        assert timedelta(minutes=30) <= idle <= timedelta(minutes=35)


def test_replay_is_deterministic():
    a, b = sim.replay(START, 10, 42), sim.replay(START, 10, 42)
    assert a["desktop"].missed == b["desktop"].missed
    assert a["gcp"].vm_hours == b["gcp"].vm_hours


@pytest.mark.parametrize("seed", range(25))
def test_gcp_never_misses_and_sleeps_most_of_the_time(seed):
    r = sim.replay(START, 10, seed)
    assert r["gcp"].missed == []
    assert r["gcp"].vm_hours < 0.1 * r["hours_total"]
    assert r["wakes_scheduler"] >= 1


@pytest.mark.parametrize("seed", range(25))
def test_desktop_misses_exactly_the_slots_it_was_off_for(seed):
    rng = sim.random.Random(seed)
    slots = sim.campaign_slots(START, 10)
    trace = sim.desktop_trace(START, 10, rng)
    for _job, slot in slots:
        on_in_window = any(a < slot + sim.GRACE and b > slot for a, b in trace.up)
        assert fires(slot, trace.up) is on_in_window


def test_planted_absence_days_have_no_uptime():
    trace = sim.desktop_trace(START, 10, sim.random.Random(3))
    for a, b in trace.absences:
        assert not any(u < b and v > a for u, v in trace.up)
