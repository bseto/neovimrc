#!/usr/bin/env python3
"""Print this key's Bifrost budget as statusline text or --json. Cache for 60s."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

URL = "https://bifrost.stackadapt.dev/api/governance/virtual-keys/quota"
CACHE = Path.home() / ".cache/nvim/bifrost-budget"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError("Invalid budget amount")
    return value


def summarize(payload):
    budgets = []
    for budget in payload.get("budgets", []):
        limit = number(budget.get("effective_max_limit", budget.get("max_limit")))
        used = number(budget.get("current_usage"))
        if limit < 0 or used < 0:
            raise ValueError("Negative budget amount")
        budgets.append({"limit": limit, "used": used, "remaining": max(0, limit - used),
                        "period": str(budget.get("reset_duration", "?")),
                        "last_reset": budget.get("last_reset")})
    # Preserve all budget windows; don't add independent caps together.
    return {"active": payload.get("is_active"), "budgets": budgets, "fetched_at": time.time(), "stale": False}


def format_status(data):
    if not data:
        return "Bifrost budget unavailable"
    if data.get("active") is False:
        return "Bifrost key inactive"
    budgets = data.get("budgets", [])
    if not budgets:
        text = "Bifrost: no key budget reported"
    else:
        text = "Bifrost " + " | ".join(
            f"${b['remaining']:,.2f}/${b['limit']:,.0f} left ({b['period']})" for b in budgets)
    return text + (" [stale]" if data.get("stale") else "")


def credential():
    if os.environ.get("BIFROST_API_KEY"):
        return os.environ["BIFROST_API_KEY"].strip()
    result = subprocess.run(["security", "find-generic-password", "-s", "bifrost_api_key", "-w"],
                            capture_output=True, text=True, timeout=10)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("Bifrost key unavailable")
    return result.stdout.strip()


def fetch(key):
    request = urllib.request.Request(URL, headers={"x-bf-vk": key, "Accept": "application/json"})
    # Never forward credentials to a redirect destination.
    with urllib.request.build_opener(NoRedirect).open(request, timeout=10) as response:
        return summarize(json.load(response))


def lookup(force=False):
    key = credential()
    CACHE.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Separate caches for different credentials without persisting the key.
    path = CACHE / (hashlib.sha256(key.encode()).hexdigest() + ".json")
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            data = None
        if not force and data and time.time() - data.get("checked_at", 0) < 60:
            return data
        try:
            data = fetch(key)
        except (OSError, ValueError):
            data = dict(data or {"budgets": [], "fetched_at": None})
            data.update(stale=True, error="Budget refresh failed")
        data["checked_at"] = time.time()
        handle, temporary = tempfile.mkstemp(dir=CACHE)
        try:
            with os.fdopen(handle, "w") as file:
                json.dump(data, file)
            os.replace(temporary, path)
        finally:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(temporary)
        return data


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="Emit normalized budget amounts and freshness")
    parser.add_argument("--refresh", action="store_true", help="Ignore the 60-second cache")
    args = parser.parse_args()
    try:
        data = lookup(args.refresh)
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        data = {"budgets": [], "fetched_at": None, "stale": True, "error": "Budget unavailable"}
    data["text"] = format_status(data) if data.get("fetched_at") else "Bifrost budget unavailable"
    print(json.dumps(data) if args.json else data["text"])


if __name__ == "__main__":
    main()
