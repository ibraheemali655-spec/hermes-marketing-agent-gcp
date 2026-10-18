"""Replay the 10-week LinkedIn campaign on both hosts and price the result.

    python run_demo.py --seed 42

Everything here runs offline: no GCP, no LinkedIn, no model calls.
"""
from __future__ import annotations

import argparse
from datetime import date

from hermes_gcp import costs, sim

CAMPAIGN_START = date(2026, 5, 18)   # Monday of the campaign's first week
WEEKS = 10


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--weeks", type=int, default=WEEKS)
    ap.add_argument("--trials", type=int, default=200, help="seeds for the miss-rate summary")
    args = ap.parse_args()

    r = sim.replay(CAMPAIGN_START, args.weeks, args.seed)
    desk, gcp = r["desktop"], r["gcp"]
    total_h = r["hours_total"]

    print(f"Campaign: {len(r['slots'])} scheduled posts over {args.weeks} weeks (Tue/Thu/Sat 09:00 Cairo), seed {args.seed}\n")

    print("Scheduled posts that actually ran")
    print(f"  {'host':<28}{'ran':>6}{'missed':>8}")
    print(f"  {'desktop VM on a laptop':<28}{desk.fired:>6}{len(desk.missed):>8}")
    print(f"  {'GCP VM, wake-on-demand':<28}{gcp.fired:>6}{len(gcp.missed):>8}")
    print(f"  planted laptop absences: {len(r['absences'])}, posts lost inside them: {len(r['missed_in_absences'])}, "
          f"lost to ordinary off-hours: {len(desk.missed) - len(r['missed_in_absences'])}")
    for name, slot in desk.missed:
        print(f"    missed on desktop: {slot:%a %d %b} {name}")

    trials = [sim.replay(CAMPAIGN_START, args.weeks, s) for s in range(args.trials)]
    d_missed = [len(t["desktop"].missed) for t in trials]
    g_missed = [len(t["gcp"].missed) for t in trials]
    n = len(r["slots"])
    print(f"  across {args.trials} seeds: desktop misses {sum(d_missed) / args.trials:.1f}/{n} on average "
          f"(worst {max(d_missed)}), GCP misses {sum(g_missed)} in total")

    print("\nGCP VM uptime")
    print(f"  awake {gcp.vm_hours:.1f} h of {total_h} h ({100 * gcp.vm_hours / total_h:.1f}%), "
          f"{r['wakes_scheduler']} scheduler wakes, {r['wakes_telegram']} Telegram wakes")

    month_h = gcp.vm_hours / (args.weeks * 7 * 24) * costs.HOURS_PER_MONTH
    rows = [costs.infra_month("always on", costs.HOURS_PER_MONTH),
            costs.infra_month("wake-on-demand", month_h)]
    print("\nInfrastructure per month (same VM, same disk)")
    print(f"  {'mode':<18}{'VM hours':>10}{'compute':>10}{'disk':>8}{'total':>9}")
    for c in rows:
        print(f"  {c.label:<18}{c.vm_hours:>10.0f}{c.compute:>10.2f}{c.disk:>8.2f}{c.total:>9.2f}")
    print(f"  saving: {100 * (1 - rows[1].total / rows[0].total):.0f}%")

    llm = costs.llm_month()
    base = llm["deepseek/deepseek-v4-flash"]
    print("\nModel cost per month for the campaign's scheduled runs (illustrative token profile)")
    for model, usd in sorted(llm.items(), key=lambda kv: kv[1]):
        print(f"  {model:<30}{usd:>8.2f}  {usd / base:>5.1f}x")


if __name__ == "__main__":
    main()
