#!/usr/bin/env python3
"""Turn cursor-usage JSON (and optional fleet-report JSON) into gog sheets payload."""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone


def die(msg: str, code: int = 2) -> None:
    print(f"export-agent-spend-sheet: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError as e:
        die(f"cannot read {path}: {e}")
    except json.JSONDecodeError as e:
        die(f"{path} is not JSON: {e}")
    if not isinstance(data, dict):
        die(f"{path} must be an object")
    return data


def coverage_rows(cursor: dict, fleet: dict | None, generated: str) -> list[list[str]]:
    totals = cursor.get("totals") or {}
    days = cursor.get("days") or []
    first = days[0]["date"] if days else ""
    last = days[-1]["date"] if days else ""
    rows = [
        ["Fitcode agent spend history"],
        ["Generated (UTC)", generated],
        [],
        [
            "Cursor charged USD is what Cursor billed (chargedCents/100). "
            "List USD is the token list-price estimate (tokenUsage.totalCents/100). "
            "They are not the same."
        ],
        [
            "Cursor numbers come from Cursor's account usage API using the signed-in "
            "desktop app. They are account-wide, not per Mac. They are not in local files."
        ],
        [
            "The fleet tab is ccusage local logs on the Macs (Claude, Codex, Copilot, "
            "Antigravity, Pi, Grok, jcode). Cursor is not in that tab."
        ],
        [
            "Still blank on purpose: ChatGPT Work mode, agy (no usage transcripts), "
            "forge-agent (no data found)."
        ],
        [],
        ["Cursor events", str(totals.get("events", ""))],
        ["Cursor charged USD", str(totals.get("charged_usd", ""))],
        ["Cursor list USD", str(totals.get("list_usd", ""))],
        ["Cursor first day", first],
        ["Cursor last day", last],
    ]
    if fleet and isinstance(fleet.get("totals"), dict):
        rows.extend(
            [
                [],
                ["Fleet totalCost (this export)", str(fleet["totals"].get("totalCost", ""))],
                ["Fleet totalTokens", str(fleet["totals"].get("totalTokens", ""))],
            ]
        )
    return rows


def cursor_table(items: list, key: str) -> list[list[str]]:
    out = [[key, "charged_usd", "list_usd", "events"]]
    for row in items:
        out.append(
            [
                str(row.get(key, "")),
                str(row.get("charged_usd", "")),
                str(row.get("list_usd", "")),
                str(row.get("events", "")),
            ]
        )
    return out


def fleet_table(fleet: dict | None) -> list[list[str]]:
    header = ["period", "totalCost", "totalTokens", "agents"]
    if not fleet:
        return [header, ["(no fleet JSON in this export)", "", "", ""]]
    kind = next((k for k in ("monthly", "weekly", "daily") if k in fleet), None)
    if not kind:
        return [header, ["(fleet JSON has no daily/weekly/monthly rows)", "", "", ""]]
    out = [header]
    for row in fleet[kind]:
        agents = ""
        meta = row.get("metadata") or {}
        if isinstance(meta.get("agents"), list):
            agents = ", ".join(str(a) for a in meta["agents"])
        out.append(
            [
                str(row.get("period", "")),
                str(row.get("totalCost", "")),
                str(row.get("totalTokens", "")),
                agents,
            ]
        )
    totals = fleet.get("totals") or {}
    out.append(
        [
            "TOTAL",
            str(totals.get("totalCost", "")),
            str(totals.get("totalTokens", "")),
            "",
        ]
    )
    return out


def payload(cursor: dict, fleet: dict | None, generated: str) -> list[dict]:
    return [
        {"range": "'Read me'!A1", "values": coverage_rows(cursor, fleet, generated)},
        {"range": "'Cursor monthly'!A1", "values": cursor_table(cursor.get("months") or [], "month")},
        {"range": "'Cursor daily'!A1", "values": cursor_table(cursor.get("days") or [], "date")},
        {"range": "'Fleet monthly'!A1", "values": fleet_table(fleet)},
    ]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--cursor-json", required=True)
    p.add_argument("--fleet-json")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    if not args.json:
        die("pass --json")
    cursor = load_json(args.cursor_json)
    fleet = load_json(args.fleet_json) if args.fleet_json else None
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    body = payload(cursor, fleet, generated)
    dumped = json.dumps(body)
    if "secret@example.com" in dumped:
        die("payload leaked owningUser email")
    json.dump(body, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
