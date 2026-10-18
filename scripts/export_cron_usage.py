#!/usr/bin/env python3
"""Export per-run usage of Hermes cron jobs from ~/.hermes/state.db to a CSV.

Only counts leave the database: tokens, tool calls, duration and Hermes's own cost estimate.
No prompts, no messages, no titles.

    python scripts/export_cron_usage.py [STATE_DB] [-o data/measured_cron_runs.csv] [--utc-offset 3]
"""
from __future__ import annotations

import argparse
import csv
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

QUERY = """
select started_at, ended_at, input_tokens, cache_read_tokens, output_tokens, tool_call_count,
       estimated_cost_usd
from sessions where source = 'cron' order by started_at
"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("db", nargs="?", default=str(Path.home() / ".hermes/state.db"))
    ap.add_argument("-o", "--out", default="data/measured_cron_runs.csv")
    ap.add_argument("--utc-offset", type=float, default=0, help="hours, for the date column")
    args = ap.parse_args()

    tz = timezone(timedelta(hours=args.utc_offset))
    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["date", "weekday", "uncached_input_tokens", "cache_read_tokens", "output_tokens",
                    "tool_calls", "duration_s", "cost_usd"])
        n = 0
        for started, ended, inp, cache, out, tools, cost in con.execute(QUERY):
            d = datetime.fromtimestamp(started, tz)
            dur = "" if ended is None else round(ended - started)
            w.writerow([d.date(), d.strftime("%a"), inp or 0, cache or 0, out or 0, tools or 0, dur,
                        "" if cost is None else round(cost, 4)])
            n += 1
    print(f"wrote {n} cron runs to {args.out}")


if __name__ == "__main__":
    main()
