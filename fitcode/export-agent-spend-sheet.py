#!/usr/bin/env python3
"""Master fact table plus a prune dashboard. Cursor is a source, not a side tab."""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
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


def money(value) -> float:
    try:
        return round(float(value or 0), 2)
    except (TypeError, ValueError):
        return 0.0


def classify_model(name: str) -> tuple[str, str, str]:
    rest = (name or "unknown").strip()
    if rest.startswith("[") and "]" in rest:
        rest = rest[rest.index("]") + 1 :].strip() or rest
    low = rest.lower()
    if "claude" in low:
        family = "Claude"
    elif "gemini" in low:
        family = "Gemini"
    elif "grok" in low:
        family = "Grok"
    elif "composer" in low:
        family = "Composer"
    elif "kimi" in low:
        family = "Kimi"
    elif "bugbot" in low or "agent_review" in low:
        family = "Cursor extra"
    elif low in {"default", "auto"}:
        family = "Cursor Auto"
    elif re.search(r"(^|[^a-z])(gpt|o1|o3|o4)", low):
        family = "OpenAI"
    else:
        family = "Other"
    effort = "unspecified"
    for pat in (
        "extra-high",
        "high-thinking",
        "medium-thinking",
        "low-thinking",
        "high-fast",
        "thinking",
        "fast",
    ):
        if pat in low:
            effort = pat
            break
    if effort == "unspecified" and (low.endswith("-high") or "-high-" in low):
        effort = "high"
    return rest, family, effort


def prune_call(this_month: float, last_month: float, all_time: float) -> str:
    if all_time < 50 and this_month < 10:
        return "Cut candidate"
    if this_month >= 50 or all_time >= 100:
        return "Keep"
    return "Watch"


def master_rows(mini: dict | None, macbook: dict | None, cursor: dict | None) -> list[list]:
    rows: list[list] = [["Month", "Machine", "Source", "Family", "Model", "Effort", "Spend"]]

    def from_report(report: dict | None, machine: str) -> None:
        if not report:
            return
        for row in report.get("monthly") or []:
            period = str(row.get("period") or "")
            agents = row.get("agents") or []
            if agents:
                for agent_row in agents:
                    source = str(agent_row.get("agent") or "unknown")
                    for bd in agent_row.get("modelBreakdowns") or []:
                        usd = money(bd.get("cost"))
                        if usd == 0:
                            continue
                        model, family, effort = classify_model(str(bd.get("modelName") or "unknown"))
                        rows.append([period, machine, source, family, model, effort, usd])
            else:
                for bd in row.get("modelBreakdowns") or []:
                    usd = money(bd.get("cost"))
                    if usd == 0:
                        continue
                    model, family, effort = classify_model(str(bd.get("modelName") or "unknown"))
                    rows.append([period, machine, "unknown", family, model, effort, usd])

    from_report(mini, "mini")
    from_report(macbook, "macbook")
    if cursor:
        for item in cursor.get("by_month_model") or []:
            usd = money(item.get("charged_usd"))
            if usd == 0:
                continue
            model, family, effort = classify_model(str(item.get("model") or "unknown"))
            rows.append(
                [
                    str(item.get("month") or ""),
                    "account",
                    "cursor",
                    family,
                    model,
                    effort,
                    usd,
                ]
            )
    dumped = json.dumps(rows)
    if "secret@example.com" in dumped:
        die("payload leaked owningUser email")
    return rows


def facts(master: list[list]) -> list[dict]:
    out = []
    for row in master[1:]:
        if len(row) < 7:
            continue
        out.append(
            {
                "month": row[0],
                "machine": row[1],
                "source": row[2],
                "family": row[3],
                "model": row[4],
                "effort": row[5],
                "spend": money(row[6]),
            }
        )
    return out


def dashboard_and_helpers(master: list[list]) -> tuple[list[list], list[list], list[list]]:
    rows = facts(master)
    months = sorted({r["month"] for r in rows if r["month"]})
    this_month = months[-1] if months else ""
    last_month = months[-2] if len(months) > 1 else ""
    shop = round(sum(r["spend"] for r in rows), 2)
    this_spend = round(sum(r["spend"] for r in rows if r["month"] == this_month), 2)
    last_spend = round(sum(r["spend"] for r in rows if r["month"] == last_month), 2)
    delta = round(this_spend - last_spend, 2)

    by_source_all: dict[str, float] = defaultdict(float)
    by_source_this: dict[str, float] = defaultdict(float)
    by_source_last: dict[str, float] = defaultdict(float)
    by_model: dict[str, float] = defaultdict(float)
    for r in rows:
        by_source_all[r["source"]] += r["spend"]
        by_model[r["model"]] += r["spend"]
        if r["month"] == this_month:
            by_source_this[r["source"]] += r["spend"]
        if r["month"] == last_month:
            by_source_last[r["source"]] += r["spend"]

    prune: list[list] = [["Source", "This month", "Last month", "All time", "Call"]]
    for source in sorted(by_source_all, key=lambda s: -by_source_all[s]):
        this = round(by_source_this[source], 2)
        last = round(by_source_last[source], 2)
        all_time = round(by_source_all[source], 2)
        prune.append([source, this, last, all_time, prune_call(this, last, all_time)])

    top_models = sorted(by_model.items(), key=lambda kv: -kv[1])[:8]
    top_block: list[list] = [["Top models (all time)", "Spend"]]
    for name, usd in top_models:
        top_block.append([name, round(usd, 2)])

    dash: list[list] = [
        ["Agent spend"],
        ["One master table. This tab is the prune view."],
        ["As of (UTC)", datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")],
        [],
        ["Shop total", shop],
        ["This month", this_month],
        ["This month spend", this_spend],
        ["Last month", last_month],
        ["Last month spend", last_spend],
        ["Change", delta],
        [],
        ["What to do"],
    ]
    dash.extend(prune)
    dash.append([])
    dash.extend(top_block)
    dash.append([])
    dash.append(["Still missing", "ChatGPT Work, agy, forge-agent, dsh"])
    dash.append(["Cursor machine", "account — cannot split Mini vs MacBook"])

    monthly: dict[str, dict[str, float]] = defaultdict(lambda: {"mini": 0.0, "macbook": 0.0, "cursor": 0.0})
    for r in rows:
        bucket = "cursor" if r["source"] == "cursor" else r["machine"]
        if bucket not in ("mini", "macbook", "cursor"):
            bucket = "cursor"
        monthly[r["month"]][bucket] = round(monthly[r["month"]][bucket] + r["spend"], 2)
    chart_month: list[list] = [["Month", "Mini", "MacBook", "Cursor", "Combined"]]
    for month in months:
        a = monthly[month]["mini"]
        b = monthly[month]["macbook"]
        c = monthly[month]["cursor"]
        chart_month.append([month, a, b, c, round(a + b + c, 2)])

    chart_source: list[list] = [["Source", "This month", "Last month"]]
    for source in sorted(by_source_all, key=lambda s: -by_source_this[s]):
        chart_source.append(
            [source, round(by_source_this[source], 2), round(by_source_last[source], 2)]
        )
    return dash, chart_month, chart_source


def payload(mini: dict | None, macbook: dict | None, cursor: dict | None) -> list[dict]:
    master = master_rows(mini, macbook, cursor)
    dash, chart_month, chart_source = dashboard_and_helpers(master)
    body = [
        {"range": "Dashboard!A1", "values": dash},
        {"range": "ChartData!A1", "values": chart_month},
        {"range": "ChartData!G1", "values": chart_source},
        {"range": "Master!A1", "values": master},
    ]
    dumped = json.dumps(body)
    if "secret@example.com" in dumped:
        die("payload leaked owningUser email")
    return body


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--mini-json")
    p.add_argument("--macbook-json")
    p.add_argument("--cursor-json")
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)
    if not args.json:
        die("pass --json")
    if not (args.mini_json or args.macbook_json or args.cursor_json):
        die("pass --mini-json, --macbook-json, and/or --cursor-json")
    mini = load_json(args.mini_json) if args.mini_json else None
    macbook = load_json(args.macbook_json) if args.macbook_json else None
    cursor = load_json(args.cursor_json) if args.cursor_json else None
    json.dump(payload(mini, macbook, cursor), sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
