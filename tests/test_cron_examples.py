import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_example_jobs_cover_the_weekly_rhythm():
    jobs = json.loads((ROOT / "hermes/cron/jobs.example.json").read_text())["jobs"]
    assert [j["schedule"]["expr"] for j in jobs] == ["0 9 * * 2", "0 9 * * 4", "0 9 * * 6"]
    for j in jobs:
        assert j["skill"] == "campaign-cmo"
        assert "browser" in j["enabled_toolsets"]
        assert "<PAGE_ID>" in j["prompt"]
        assert "Schedule post" in j["prompt"]
