#!/usr/bin/env python3
"""Compute the Cloud Scheduler expression that wakes the VM before the next Hermes cron job.

Reads Hermes's own job store (~/.hermes/cron/jobs.json), so a job added later from Telegram
is covered automatically; nothing about the schedule is hardcoded in the infrastructure.

Prints one cron expression in UTC, e.g. ``52 5 9 6 *``. It names one specific minute; the
VM rewrites it again before every shutdown, so it never needs to repeat. When there's nothing
to wake for, it prints PARK (1 January, midnight), which Scheduler accepts and which is
always overwritten before it matters.

Usage: nextwake.py [JOBS_FILE] [--lead-min N] [--now ISO8601]
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

PARK = "0 0 1 1 *"
DEFAULT_LEAD_MIN = 8


def due_runs(jobs: list[dict], now: datetime) -> list[datetime]:
    """Future run times of the jobs that will actually fire."""
    runs = []
    for job in jobs:
        if not job.get("enabled") or job.get("state") == "paused":
            continue
        raw = job.get("next_run_at")
        if not raw:
            continue
        try:
            at = datetime.fromisoformat(raw)
        except ValueError:
            continue
        if at.tzinfo is None:  # Hermes writes offsets; refuse to guess a naive time's zone
            continue
        if at > now:
            runs.append(at)
    return runs


def next_wake(jobs: list[dict], now: datetime, lead_min: int = DEFAULT_LEAD_MIN) -> str:
    runs = due_runs(jobs, now)
    if not runs:
        return PARK
    wake = min(runs).astimezone(timezone.utc) - timedelta(minutes=lead_min)
    # A job due within the lead window: wake now-ish rather than a minute already gone.
    wake = max(wake, now.astimezone(timezone.utc) + timedelta(minutes=1))
    return f"{wake.minute} {wake.hour} {wake.day} {wake.month} *"


def load_jobs(path: Path) -> list[dict]:
    data = json.loads(path.read_text())
    return data.get("jobs", []) if isinstance(data, dict) else data


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("jobs_file", nargs="?", default=str(Path.home() / ".hermes/cron/jobs.json"))
    ap.add_argument("--lead-min", type=int, default=DEFAULT_LEAD_MIN)
    ap.add_argument("--now", help="ISO-8601 timestamp with offset (tests and dry runs)")
    args = ap.parse_args(argv)

    now = datetime.fromisoformat(args.now) if args.now else datetime.now(timezone.utc)
    try:
        jobs = load_jobs(Path(args.jobs_file))
    except (OSError, ValueError) as e:
        print(f"nextwake: cannot read {args.jobs_file}: {e}", file=sys.stderr)
        print(PARK)
        return 0
    print(next_wake(jobs, now, args.lead_min))
    return 0


if __name__ == "__main__":
    sys.exit(main())
