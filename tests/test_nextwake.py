import json
from datetime import datetime, timezone

import nextwake
from nextwake import PARK, next_wake

NOW = datetime(2026, 6, 1, 12, 0, tzinfo=timezone.utc)


def job(at, **kw):
    return {"enabled": True, "state": "scheduled", "next_run_at": at, **kw}


def test_wakes_lead_minutes_before_earliest_job_in_utc():
    jobs = [job("2026-06-04T09:00:00+03:00"), job("2026-06-02T09:00:00+03:00")]
    # 09:00 +03:00 = 06:00 UTC, minus 8 minutes
    assert next_wake(jobs, NOW) == "52 5 2 6 *"


def test_lead_is_configurable():
    assert next_wake([job("2026-06-02T09:00:00+03:00")], NOW, lead_min=15) == "45 5 2 6 *"


def test_disabled_and_paused_jobs_do_not_wake_the_vm():
    jobs = [job("2026-06-02T09:00:00+03:00", enabled=False),
            job("2026-06-03T09:00:00+03:00", state="paused"),
            job("2026-06-05T09:00:00+03:00")]
    assert next_wake(jobs, NOW) == "52 5 5 6 *"


def test_past_runs_are_ignored():
    # A slot already behind us would schedule a wake that only fires next year.
    jobs = [job("2026-05-30T09:00:00+03:00"), job("2026-06-06T09:00:00+03:00")]
    assert next_wake(jobs, NOW) == "52 5 6 6 *"


def test_job_inside_the_lead_window_wakes_within_a_minute():
    soon = job("2026-06-01T15:05:00+03:00")   # 12:05 UTC, 5 minutes from NOW
    assert next_wake([soon], NOW) == "1 12 1 6 *"


def test_nothing_to_wake_for_parks_the_scheduler():
    assert next_wake([], NOW) == PARK
    assert next_wake([job(None)], NOW) == PARK
    assert next_wake([job("2026-06-02T09:00:00")], NOW) == PARK   # naive time: zone unknown


def test_cli_reads_hermes_jobs_file(tmp_path, capsys):
    f = tmp_path / "jobs.json"
    f.write_text(json.dumps({"jobs": [job("2026-06-02T09:00:00+03:00")]}))
    nextwake.main([str(f), "--now", NOW.isoformat()])
    assert capsys.readouterr().out.strip() == "52 5 2 6 *"


def test_cli_parks_on_unreadable_file(tmp_path, capsys):
    nextwake.main([str(tmp_path / "missing.json")])
    assert capsys.readouterr().out.strip() == PARK
