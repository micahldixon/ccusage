#!/usr/bin/env python3
"""Add together two or more ccusage all-agents JSON reports into one report of the
same shape, on stdout. fleet-report.sh --fleet uses it to add the two Macs.

The inputs are whatever `fitcode/fleet-report.sh daily|weekly|monthly [--by-agent]
--json` prints on one machine. Rows match on their `period` value; every numeric
token/cost field adds; `modelBreakdowns` add per `modelName`; `modelsUsed` and
`metadata.agents` become sorted unions; a `--by-agent` report's nested `agents[]`
merge the same way, per `agent`. The merged rows are sorted by period, newest first
when every input with two or more rows lists them that way (`--order desc`), else
oldest first. `totals` is recomputed from the merged rows and cross-checked against
the sum of every input's own `totals` (a trip-wire against dropped or double-counted
data).

Usage:
  merge-reports.py FILE...

Exit non-zero, with a message on stderr, rather than guess, when:
  - no input files are given;
  - the inputs are not all the same report kind (daily vs weekly vs monthly);
  - a report is not the all-agents daily/weekly/monthly shape (session and blocks
    reports are not);
  - any object anywhere in an input carries a key this script does not recognize;
  - the recomputed totals do not equal the sum of the inputs' own totals.

Python 3 stdlib only.
"""

from __future__ import annotations

import copy
import json
import math
import sys

TOKEN_KEYS = (
    "inputTokens",
    "outputTokens",
    "cacheCreationTokens",
    "cacheReadTokens",
    "totalTokens",
)

KIND_KEYS = {"daily", "weekly", "monthly"}

# Keys a top-level *row* (one period, agent "all") is allowed to carry.
ROW_KEYS = {
    "agent",
    "modelsUsed",
    "inputTokens",
    "outputTokens",
    "cacheCreationTokens",
    "cacheReadTokens",
    "totalTokens",
    "totalCost",
    "modelBreakdowns",
    "period",
    "metadata",
    "agents",
}

# Keys a nested per-agent row (inside a `--by-agent` row's "agents" list) is
# allowed to carry. Same as ROW_KEYS minus the fields only the top row gets.
NESTED_AGENT_ROW_KEYS = ROW_KEYS - {"period", "metadata", "agents"}

MODEL_BREAKDOWN_KEYS = {
    "modelName",
    "inputTokens",
    "outputTokens",
    "cacheCreationTokens",
    "cacheReadTokens",
    "cost",
}

METADATA_KEYS = {"agents"}

TOTALS_KEYS = set(TOKEN_KEYS) | {"totalCost"}


def fail(message: str) -> "typing.NoReturn":  # type: ignore[name-defined]
    print(f"merge-reports: {message}", file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------------------
# Loading and validation
# --------------------------------------------------------------------------


def load_report(path: str):
    """Read and validate one report file. Returns (kind, data)."""
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    except json.JSONDecodeError as error:
        fail(f"{path}: not valid JSON ({error})")
    if not isinstance(data, dict):
        fail(f"{path}: report is not a JSON object")
    keys = set(data.keys())
    kinds_present = keys & KIND_KEYS
    if len(kinds_present) != 1:
        fail(
            f"{path}: expected exactly one of daily/weekly/monthly at the top "
            f"level, found {sorted(keys)}"
        )
    kind = next(iter(kinds_present))
    extra = keys - {kind, "totals"}
    if extra:
        fail(f"{path}: unrecognized top-level key(s) {sorted(extra)}")
    if "totals" not in keys:
        fail(f"{path}: missing 'totals'")
    rows = data[kind]
    if not isinstance(rows, list):
        fail(f"{path}: '{kind}' is not a list")
    for row in rows:
        validate_row(row, path, nested=False)
    validate_totals(data["totals"], path)
    return kind, data


def validate_row(row, path: str, *, nested: bool) -> None:
    if not isinstance(row, dict):
        fail(f"{path}: a {'nested agent ' if nested else ''}row is not an object")
    allowed = NESTED_AGENT_ROW_KEYS if nested else ROW_KEYS
    extra = set(row.keys()) - allowed
    if extra:
        fail(f"{path}: unrecognized row key(s) {sorted(extra)}")
    if not nested and "period" not in row:
        fail(f"{path}: row is missing 'period'")
    metadata = row.get("metadata")
    if metadata is not None:
        if not isinstance(metadata, dict):
            fail(f"{path}: 'metadata' is not an object")
        extra_meta = set(metadata.keys()) - METADATA_KEYS
        if extra_meta:
            fail(f"{path}: unrecognized metadata key(s) {sorted(extra_meta)}")
    for breakdown in row.get("modelBreakdowns") or []:
        if not isinstance(breakdown, dict):
            fail(f"{path}: a modelBreakdowns entry is not an object")
        extra_mb = set(breakdown.keys()) - MODEL_BREAKDOWN_KEYS
        if extra_mb:
            fail(f"{path}: unrecognized modelBreakdowns key(s) {sorted(extra_mb)}")
    if not nested:
        for nested_row in row.get("agents") or []:
            validate_row(nested_row, path, nested=True)


def validate_totals(totals, path: str) -> None:
    if not isinstance(totals, dict):
        fail(f"{path}: 'totals' is not an object")
    extra = set(totals.keys()) - TOTALS_KEYS
    if extra:
        fail(f"{path}: unrecognized totals key(s) {sorted(extra)}")
    missing = TOTALS_KEYS - set(totals.keys())
    if missing:
        fail(f"{path}: 'totals' is missing key(s) {sorted(missing)}")


# --------------------------------------------------------------------------
# Merge
# --------------------------------------------------------------------------


def merge_model_breakdowns(a_list, b_list):
    by_name: dict[str, dict] = {}
    for breakdown in a_list:
        by_name[breakdown["modelName"]] = dict(breakdown)
    for breakdown in b_list:
        name = breakdown["modelName"]
        if name in by_name:
            existing = by_name[name]
            merged = dict(existing)
            for key in (
                "inputTokens",
                "outputTokens",
                "cacheCreationTokens",
                "cacheReadTokens",
            ):
                merged[key] = existing.get(key, 0) + breakdown.get(key, 0)
            merged["cost"] = existing.get("cost", 0.0) + breakdown.get("cost", 0.0)
            by_name[name] = merged
        else:
            by_name[name] = dict(breakdown)
    return [by_name[name] for name in sorted(by_name)]


def merge_agent_like_row(a: dict, b: dict) -> dict:
    """Merge two rows (top-level or nested) that describe the same period+agent."""
    out = copy.deepcopy(a)
    for key in TOKEN_KEYS:
        out[key] = a.get(key, 0) + b.get(key, 0)
    out["totalCost"] = a.get("totalCost", 0.0) + b.get("totalCost", 0.0)
    out["modelsUsed"] = sorted(
        set(a.get("modelsUsed") or []) | set(b.get("modelsUsed") or [])
    )
    out["modelBreakdowns"] = merge_model_breakdowns(
        a.get("modelBreakdowns") or [], b.get("modelBreakdowns") or []
    )
    return out


def merge_nested_agents(a_list, b_list):
    by_agent: dict[str, dict] = {}
    for item in a_list:
        by_agent[item["agent"]] = copy.deepcopy(item)
    for item in b_list:
        name = item["agent"]
        by_agent[name] = (
            merge_agent_like_row(by_agent[name], item) if name in by_agent else copy.deepcopy(item)
        )
    return [by_agent[name] for name in sorted(by_agent)]


def merge_row(a: dict, b: dict) -> dict:
    out = merge_agent_like_row(a, b)
    a_agents = set((a.get("metadata") or {}).get("agents") or [])
    b_agents = set((b.get("metadata") or {}).get("agents") or [])
    merged_agents = a_agents | b_agents
    if merged_agents:
        out["metadata"] = {"agents": sorted(merged_agents)}
    elif "metadata" in out:
        del out["metadata"]
    if "agents" in a or "agents" in b:
        out["agents"] = merge_nested_agents(a.get("agents") or [], b.get("agents") or [])
    return out


def sum_totals(items) -> dict:
    """Totals over rows or over reports' `totals` (both carry the same keys)."""
    totals = {key: 0 for key in TOKEN_KEYS}
    cost = 0.0
    for item in items:
        for key in TOKEN_KEYS:
            totals[key] += item.get(key, 0)
        cost += item.get("totalCost", 0.0)
    totals["totalCost"] = cost
    return totals


def totals_mismatch(a: dict, b: dict):
    """Return the first key where a and b disagree, or None if they match."""
    for key in TOKEN_KEYS:
        if a[key] != b[key]:
            return key
    if not math.isclose(a["totalCost"], b["totalCost"], rel_tol=1e-9, abs_tol=1e-6):
        return "totalCost"
    return None


def newest_first(entries, kind: str) -> bool:
    """True when every input with two or more rows lists them newest first."""
    orders = set()
    for _, data, _ in entries:
        periods = [row["period"] for row in data[kind]]
        if len(periods) > 1:
            orders.add(periods == sorted(periods, reverse=True))
    return orders == {True}


def merge_all(entries) -> dict:
    """entries: list of (kind, data, path). Returns the merged report dict."""
    kinds = {kind for kind, _, _ in entries}
    if len(kinds) != 1:
        detail = ", ".join(f"{path} ({kind})" for kind, _, path in entries)
        fail(f"cannot merge different report kinds: {detail}")
    kind = next(iter(kinds))

    merged_by_period: dict[str, dict] = {}
    for _, data, path in entries:
        for row in data[kind]:
            period = row.get("period")
            if period in merged_by_period:
                merged_by_period[period] = merge_row(merged_by_period[period], row)
            else:
                merged_by_period[period] = copy.deepcopy(row)

    periods = sorted(merged_by_period, reverse=newest_first(entries, kind))
    rows = [merged_by_period[period] for period in periods]
    totals = sum_totals(rows)
    input_totals = sum_totals(data["totals"] for _, data, _ in entries)
    bad_key = totals_mismatch(totals, input_totals)
    if bad_key is not None:
        fail(
            "totals do not reconcile after merge: recomputed "
            f"{bad_key}={totals[bad_key]!r}, but the sum of every input's own "
            f"totals gives {bad_key}={input_totals[bad_key]!r}. This should "
            "never happen; the merge logic likely dropped or double-counted "
            "something."
        )
    return {kind: rows, "totals": totals}


def main(argv) -> int:
    if not argv:
        fail("no input files given")
    if argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    entries = [(*load_report(path), path) for path in argv]
    print(json.dumps(merge_all(entries), sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
