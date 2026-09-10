#!/usr/bin/env python3
"""Budget normalization, caching, credential isolation, and stale fallback; no network."""
import importlib.util
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("budget", Path(__file__).with_name("bifrost-budget.py"))
budget = importlib.util.module_from_spec(spec)
spec.loader.exec_module(budget)

with tempfile.TemporaryDirectory() as folder:
    budget.CACHE = Path(folder)
    budget.credential = lambda: "test-key-one"
    calls = []

    def fetch(key):
        calls.append(key)
        return budget.summarize({"is_active": True, "budgets": [
            {"max_limit": 900, "current_usage": 34.03, "reset_duration": "1M"},
            {"max_limit": 10, "effective_max_limit": 15, "current_usage": 16, "reset_duration": "1d"},
        ]})

    budget.fetch = fetch
    data = budget.lookup()
    assert data["budgets"][0]["remaining"] == 865.97
    assert data["budgets"][1]["remaining"] == 0
    assert "$865.97/$900" in budget.format_status(data)
    budget.lookup()
    assert len(calls) == 1

    def offline(_):
        raise OSError("offline")

    budget.fetch = offline
    stale = budget.lookup(force=True)
    assert stale["stale"] and stale["budgets"] == data["budgets"]
    assert budget.format_status(stale).endswith("[stale]")
    budget.credential = lambda: "test-key-two"
    assert budget.lookup()["fetched_at"] is None
    for path in Path(folder).glob("*.json"):
        assert "test-key" not in path.read_text()
    try:
        budget.summarize({"budgets": [{"max_limit": 10, "current_usage": float("nan")}]})
        raise AssertionError("Invalid amount accepted")
    except ValueError:
        pass
print("Budget cache, independent limits, stale fallback, and credential isolation checks passed")
