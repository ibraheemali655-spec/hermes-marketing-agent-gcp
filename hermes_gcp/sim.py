"""Replay a campaign's cron schedule against two ways of hosting the agent.

desktop  The agent lives in a VM on the owner's laptop. It runs whenever the laptop is on.
         The laptop's on/off pattern is synthetic and seeded, with planted multi-day
         absences (travel, a dead battery). This is how the agent ran before GCP.
gcp      The agent lives on a GCP VM that's off by default. Cloud Scheduler starts it
         WAKE_LEAD_MIN before each due job, Telegram messages start it on demand, and
         the idle watchdog stops it after IDLE_MIN of nothing.

Both hosts run the same Hermes scheduler semantics: a job whose slot passes while the
gateway is down still fires if the gateway comes up within GRACE. Otherwise the run is
skipped and the job fast-forwards to its next occurrence. Hermes never catches up.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Africa/Cairo")
GRACE = timedelta(hours=2)          # Hermes cron grace (grace=7200s in agent.log)
WAKE_LEAD = timedelta(minutes=8)    # infra/config.example.sh WAKE_LEAD_MIN
IDLE_MIN = 60                       # infra/vm/idle-watchdog.sh IDLE_THRESHOLD_MIN
WATCHDOG_EVERY = 5                  # idle-watchdog.timer OnUnitActiveSec
WATCHDOG_FIRST = 10                 # idle-watchdog.timer OnBootSec

Interval = tuple[datetime, datetime]


@dataclass(frozen=True)
class Job:
    name: str
    weekday: int   # Monday=0
    at: time


CAMPAIGN_JOBS = (
    Job("tue-campaign-post", 1, time(9, 0)),
    Job("thu-industry-commentary", 3, time(9, 0)),
    Job("sat-educational-post", 5, time(9, 0)),
)


def campaign_slots(start: date, weeks: int, jobs=CAMPAIGN_JOBS) -> list[tuple[Job, datetime]]:
    slots = []
    for d in range(weeks * 7):
        day = start + timedelta(days=d)
        for job in jobs:
            if day.weekday() == job.weekday:
                slots.append((job, datetime.combine(day, job.at, TZ)))
    return sorted(slots, key=lambda s: s[1])


def merge(intervals: list[Interval]) -> list[Interval]:
    out: list[Interval] = []
    for a, b in sorted(intervals):
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def hours(intervals: list[Interval]) -> float:
    return sum((b - a).total_seconds() for a, b in intervals) / 3600


def first_up_at_or_after(t: datetime, up: list[Interval]) -> datetime | None:
    for a, b in up:
        if a <= t < b:
            return t
        if a > t:
            return a
    return None


def fires(slot: datetime, up: list[Interval]) -> bool:
    """Hermes semantics: the job runs if the gateway is up at the slot or within GRACE after it."""
    t = first_up_at_or_after(slot, up)
    return t is not None and t - slot <= GRACE


# ----------------------------------------------------------------- desktop ---

@dataclass
class DesktopTrace:
    up: list[Interval]
    absences: list[Interval] = field(default_factory=list)   # planted, whole days off


def desktop_trace(start: date, weeks: int, rng: random.Random,
                  n_absences: int = 2) -> DesktopTrace:
    """A laptop that's on during the working day, sometimes at weekends, and occasionally not at all."""
    days = weeks * 7
    absent: set[int] = set()
    absences: list[Interval] = []
    for _ in range(n_absences):
        first = rng.randrange(days)
        length = rng.randint(1, 3)
        span = [d for d in range(first, min(first + length, days))]
        absent.update(span)
        absences.append((datetime.combine(start + timedelta(days=span[0]), time(0), TZ),
                         datetime.combine(start + timedelta(days=span[-1] + 1), time(0), TZ)))

    up: list[Interval] = []
    for d in range(days):
        if d in absent:
            continue
        day = start + timedelta(days=d)
        weekend = day.weekday() in (4, 5)    # Fri/Sat weekend
        if rng.random() > (0.90 if weekend else 0.97):
            continue
        # Switched on some time in the morning; later on weekends.
        on = datetime.combine(day, time(7, 30), TZ) + timedelta(minutes=rng.randint(0, 180 if weekend else 120))
        length = timedelta(minutes=rng.randint(240, 840) if not weekend else rng.randint(120, 480))
        up.append((on, on + length))
    return DesktopTrace(merge(up), absences)


# --------------------------------------------------------------------- gcp ---

def idle_shutdown(activity_end: datetime, booted: datetime) -> datetime:
    """When the watchdog stops the VM once activity ends.

    The timer ticks WATCHDOG_FIRST min after boot, then every WATCHDOG_EVERY. The first idle
    tick writes the marker, and the VM stops on the first tick at least IDLE_MIN later.
    """
    tick = booted + timedelta(minutes=WATCHDOG_FIRST)
    while tick < activity_end:
        tick += timedelta(minutes=WATCHDOG_EVERY)
    marker = tick
    while tick - marker < timedelta(minutes=IDLE_MIN):
        tick += timedelta(minutes=WATCHDOG_EVERY)
    return tick


@dataclass
class GcpTrace:
    up: list[Interval]
    wakes_scheduler: int
    wakes_telegram: int


def gcp_trace(slots: list[tuple[Job, datetime]], start: date, weeks: int, rng: random.Random,
              telegram_per_week: float = 4.0) -> GcpTrace:
    """Uptime of the wake-on-demand VM: scheduled wakes for every job plus ad-hoc Telegram sessions."""
    # (wake request time, how long the work keeps the agent busy once it's up, trigger)
    demands: list[tuple[datetime, timedelta, str]] = []
    for _job, slot in slots:
        run = timedelta(minutes=rng.uniform(0.5, 6))              # a cron run: read plan, post, report
        # Scheduler wakes the VM WAKE_LEAD early; boot fits inside the lead, so the
        # agent is busy from the slot until the run ends.
        demands.append((slot - WAKE_LEAD, WAKE_LEAD + run, "scheduler"))
    for d in range(weeks * 7):
        if rng.random() < telegram_per_week / 7:
            at = datetime.combine(start + timedelta(days=d), time(9), TZ) + timedelta(minutes=rng.randint(0, 720))
            demands.append((at, timedelta(minutes=rng.uniform(5, 40)), "telegram"))

    up: list[Interval] = []
    wakes = {"scheduler": 0, "telegram": 0}
    for at, busy, kind in sorted(demands):
        if up and at < up[-1][1]:
            # VM already awake: the work extends the session and resets the idle timer.
            booted = up[-1][0]
            up[-1] = (booted, max(up[-1][1], idle_shutdown(at + busy, booted)))
            continue
        # Cold start: VM boot + gateway ready (~60 s for the waker's "resend" reply in practice).
        boot = timedelta(seconds=rng.uniform(50, 90) + 30)
        assert boot < WAKE_LEAD
        activity_end = at + busy if kind == "scheduler" else at + boot + busy
        up.append((at, idle_shutdown(activity_end, at)))
        wakes[kind] += 1
    return GcpTrace(merge(up), wakes["scheduler"], wakes["telegram"])


# ----------------------------------------------------------------- results ---

@dataclass
class HostResult:
    host: str
    scheduled: int
    fired: int
    missed: list[tuple[str, datetime]]
    vm_hours: float


def replay(start: date, weeks: int, seed: int) -> dict:
    rng = random.Random(seed)
    slots = campaign_slots(start, weeks)
    desk = desktop_trace(start, weeks, rng)
    gcp = gcp_trace(slots, start, weeks, rng)

    def result(host: str, up: list[Interval]) -> HostResult:
        missed = [(job.name, slot) for job, slot in slots if not fires(slot, up)]
        return HostResult(host, len(slots), len(slots) - len(missed), missed, hours(up))

    d, g = result("desktop", desk.up), result("gcp", gcp.up)
    in_absence = [m for m in d.missed if any(a <= m[1] < b for a, b in desk.absences)]
    return {
        "slots": slots,
        "desktop": d,
        "gcp": g,
        "absences": desk.absences,
        "missed_in_absences": in_absence,
        "wakes_scheduler": gcp.wakes_scheduler,
        "wakes_telegram": gcp.wakes_telegram,
        "hours_total": weeks * 7 * 24,
    }
