#!/usr/bin/env python3
"""Aggregate Cursor billed usage events into daily/monthly JSON.

Default path is a fixture file for tests. --live reads the signed-in Cursor
app token from state.vscdb and pulls GetFilteredUsageEvents. The token is
never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import ssl
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone

API = "https://api2.cursor.sh/aiserver.v1.DashboardService"
DEFAULT_DB = os.path.expanduser(
    "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
)


def die(msg: str, code: int = 2) -> None:
    print(f"cursor-usage: {msg}", file=sys.stderr)
    raise SystemExit(code)


def parse_ts(value) -> datetime | None:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        x = float(value)
        if x > 1e12:
            x /= 1000.0
        return datetime.fromtimestamp(x, tz=timezone.utc)
    s = str(value).strip()
    if s.isdigit():
        x = float(s)
        if x > 1e12:
            x /= 1000.0
        return datetime.fromtimestamp(x, tz=timezone.utc)
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def event_money(ev: dict) -> tuple[float, float]:
    tu = ev.get("tokenUsage") or ev.get("token_usage") or {}
    if not isinstance(tu, dict):
        tu = {}
    charged = float(ev.get("chargedCents") or ev.get("charged_cents") or 0) / 100.0
    listed = float(tu.get("totalCents") or tu.get("total_cents") or 0) / 100.0
    return charged, listed


def aggregate(events: list) -> dict:
    days: dict[str, dict] = {}
    months: dict[str, dict] = {}
    totals = {"charged_usd": 0.0, "list_usd": 0.0, "events": 0}

    def bump(bucket: dict, key: str, charged: float, listed: float, model: str) -> None:
        row = bucket.setdefault(
            key,
            {"charged_usd": 0.0, "list_usd": 0.0, "events": 0, "models": defaultdict(int)},
        )
        row["charged_usd"] += charged
        row["list_usd"] += listed
        row["events"] += 1
        row["models"][model] += 1

    for ev in events:
        if not isinstance(ev, dict):
            continue
        ts = parse_ts(ev.get("timestamp"))
        if ts is None:
            continue
        charged, listed = event_money(ev)
        model = str(ev.get("model") or "unknown")
        day = ts.date().isoformat()
        month = ts.strftime("%Y-%m")
        bump(days, day, charged, listed, model)
        bump(months, month, charged, listed, model)
        totals["charged_usd"] += charged
        totals["list_usd"] += listed
        totals["events"] += 1

    def rows(bucket: dict, key_name: str) -> list[dict]:
        out = []
        for key in sorted(bucket):
            row = bucket[key]
            out.append(
                {
                    key_name: key,
                    "charged_usd": round(row["charged_usd"], 6),
                    "list_usd": round(row["list_usd"], 6),
                    "events": row["events"],
                    "models": dict(sorted(row["models"].items())),
                }
            )
        return out

    return {
        "days": rows(days, "date"),
        "months": rows(months, "month"),
        "totals": {
            "charged_usd": round(totals["charged_usd"], 6),
            "list_usd": round(totals["list_usd"], 6),
            "events": totals["events"],
        },
    }


def load_events_json(path: str) -> list:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError as e:
        die(f"cannot read events file: {e}")
    except json.JSONDecodeError as e:
        die(f"events file is not JSON: {e}")
    if isinstance(data, dict):
        data = data.get("usageEventsDisplay") or data.get("events") or []
    if not isinstance(data, list):
        die("events JSON must be a list")
    return data


def read_access_token(db_path: str) -> str:
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        row = con.execute(
            "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        ).fetchone()
    except sqlite3.Error as e:
        die(f"cannot read Cursor login database: {e}")
    if not row or not row[0]:
        die("no Cursor access token in state.vscdb; is the app signed in?")
    token = row[0]
    if isinstance(token, bytes):
        token = token.decode()
    return token.strip()


def rpc(token: str, method: str, body: dict, timeout: int = 30) -> dict:
    url = f"{API}/{method}"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Connect-Protocol-Version", "1")
    req.add_header("User-Agent", "fitcode-cursor-usage/1")
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        die(f"{method} HTTP {e.code}")
    except urllib.error.URLError as e:
        die(f"{method} network error")
    except TimeoutError:
        die(f"{method} timed out")


def fetch_live(db_path: str) -> tuple[list, dict]:
    token = read_access_token(db_path)
    me = rpc(token, "GetMe", {})
    user_id = me.get("userId")
    if not isinstance(user_id, int):
        die("GetMe did not return a numeric userId")
    created = parse_ts(me.get("createdAt")) or datetime(2020, 1, 1, tzinfo=timezone.utc)
    start_ms = str(int(created.timestamp() * 1000))
    end_ms = str(int(datetime.now(timezone.utc).timestamp() * 1000))
    events: list = []
    total = None
    for page in range(1, 200):
        data = rpc(
            token,
            "GetFilteredUsageEvents",
            {
                "userId": user_id,
                "startDate": start_ms,
                "endDate": end_ms,
                "page": page,
                "pageSize": 100,
            },
        )
        if page == 1:
            total = data.get("totalUsageEventsCount")
        batch = data.get("usageEventsDisplay") or []
        events.extend(batch)
        if not batch:
            break
        if isinstance(total, int) and len(events) >= total:
            break
    period = rpc(token, "GetCurrentPeriodUsage", {})
    meta = {
        "source": "cursor-dashboard-api",
        "user_id": user_id,
        "events_fetched": len(events),
        "events_reported": total,
        "billing_cycle_start_ms": period.get("billingCycleStart"),
        "billing_cycle_end_ms": period.get("billingCycleEnd"),
        "plan_display": period.get("displayMessage"),
    }
    return events, meta


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Aggregate Cursor usage events")
    p.add_argument("--events-json", help="fixture or saved events JSON")
    p.add_argument("--live", action="store_true", help="pull from signed-in Cursor app")
    p.add_argument("--db", default=DEFAULT_DB, help="Cursor state.vscdb path")
    p.add_argument("--json", action="store_true", help="print JSON (required)")
    args = p.parse_args(argv)
    if not args.json:
        die("pass --json")
    if args.live and args.events_json:
        die("use --live or --events-json, not both")
    if args.live:
        events, meta = fetch_live(args.db)
        report = aggregate(events)
        report["meta"] = meta
    elif args.events_json:
        report = aggregate(load_events_json(args.events_json))
    else:
        die("pass --events-json or --live")
    json.dump(report, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
