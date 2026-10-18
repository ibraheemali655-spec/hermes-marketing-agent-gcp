from hermes_gcp import costs


def test_always_on_matches_hourly_rate():
    p = costs.load("pricing.json")
    c = costs.infra_month("always on", 730, p)
    assert round(c.compute, 2) == round(730 * costs.vm_hourly(p["gcp"]), 2)
    assert c.disk == 6.0


def test_cache_reads_are_billed_at_the_cache_rate():
    price = {"input": 1.0, "cache_read": 0.1, "output": 5.0}
    profile = {"input": 1_000_000, "cache_read": 600_000, "output": 10_000}
    assert costs.run_cost(profile, price) == (400_000 * 1.0 + 600_000 * 0.1 + 10_000 * 5.0) / 1e6


def test_deepseek_is_the_cheapest_priced_model():
    llm = costs.llm_month()
    assert min(llm, key=llm.get) == "deepseek/deepseek-v4-flash"
