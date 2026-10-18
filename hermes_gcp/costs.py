"""Monthly cost of hosting the agent, and of the model that drives it."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"
HOURS_PER_MONTH = 730


def load(name: str) -> dict:
    return json.loads((DATA / name).read_text())


@dataclass
class InfraCost:
    label: str
    vm_hours: float
    compute: float
    disk: float
    serverless: float

    @property
    def total(self) -> float:
        return self.compute + self.disk + self.serverless


def vm_hourly(g: dict) -> float:
    return (g["vm_vcpus"] * g["e2_vcpu_hour"] + g["vm_ram_gb"] * g["e2_gb_ram_hour"]
            + g["external_ipv4_hour"])


def infra_month(label: str, vm_hours: float, pricing: dict | None = None) -> InfraCost:
    g = (pricing or load("pricing.json"))["gcp"]
    return InfraCost(label, vm_hours, vm_hours * vm_hourly(g), g["disk_gb"] * g["pd_balanced_gb_month"],
                     g["serverless_month"])


def run_cost(profile: dict, price: dict) -> float:
    uncached = profile["input"] - profile["cache_read"]
    return (uncached * price["input"] + profile["cache_read"] * price["cache_read"]
            + profile["output"] * price["output"]) / 1e6


def llm_month(pricing: dict | None = None, tokens: dict | None = None) -> dict[str, float]:
    """Model cost per month of the campaign's scheduled runs, for each priced model."""
    prices = (pricing or load("pricing.json"))["llm_per_mtok"]
    t = tokens or load("token_profiles.json")
    weeks = HOURS_PER_MONTH / (24 * 7)
    return {
        model: weeks * sum(n * run_cost(t["profiles"][kind], price) for kind, n in t["runs_per_week"].items())
        for model, price in prices.items()
    }
