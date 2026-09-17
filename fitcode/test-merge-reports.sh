#!/usr/bin/env bash
# Self-test for merge-reports.py. Builds small inline fixture JSONs covering every
# merge rule and refusal, and fails if the script stops handling any of them.
#
# MERGE_REPORTS can point this test at a different copy of the script (used to
# prove each check can actually fail, by running it against a deliberately
# broken copy).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${MERGE_REPORTS:-$here/merge-reports.py}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

# A refusal must exit non-zero AND print our own clean "merge-reports: ..."
# message — not just exit non-zero for any reason. Otherwise a mutant that
# turns a deliberate check into an unhandled crash (still non-zero!) would
# read as "still refused" when the intended check is gone.
refused() {
  local label="$1" rc="$2" errfile="$3"
  if [ "$rc" -ne 0 ] && grep -q '^merge-reports: ' "$errfile"; then
    pass "$label"
  else
    bad "$label (exit $rc, stderr: $(cat "$errfile"))"
  fi
}

run() {
  # run OUTVAR ARGS...  — captures stdout in OUTVAR, stderr+exit in "$tmp/err" / $?
  local outvar="$1"
  shift
  local out
  out="$(python3 "$script" "$@" 2>"$tmp/err")"
  printf -v "$outvar" '%s' "$out"
  return $?
}

get() {
  # get JSON JQ_LIKE_PYTHON_EXPR — evaluate a python expression against JSON on stdin
  python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
" <<<"$2"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# mini's 2026-08 row lists only claude-sonnet-5 in modelsUsed/metadata.agents even
# though its modelBreakdowns also carries a gpt-6-astra entry: that asymmetry is
# deliberate, so the modelsUsed/metadata.agents "sorted union" checks below actually
# require combining both inputs' lists rather than mini's list already being the
# full answer on its own.
cat >"$tmp/mini.json" <<'EOF'
{
  "monthly": [
    {
      "agent": "all", "period": "2026-08",
      "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 10, "cacheReadTokens": 5,
      "totalTokens": 165, "totalCost": 12.5,
      "modelsUsed": ["claude-sonnet-5"],
      "modelBreakdowns": [
        {"modelName": "claude-sonnet-5", "inputTokens": 60, "outputTokens": 30, "cacheCreationTokens": 10, "cacheReadTokens": 5, "cost": 8.0},
        {"modelName": "gpt-6-astra", "inputTokens": 40, "outputTokens": 20, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 4.5}
      ],
      "metadata": {"agents": ["claude"]}
    },
    {
      "agent": "all", "period": "2026-09",
      "inputTokens": 200, "outputTokens": 100, "cacheCreationTokens": 0, "cacheReadTokens": 0,
      "totalTokens": 300, "totalCost": 20.0,
      "modelsUsed": ["claude-sonnet-5"],
      "modelBreakdowns": [
        {"modelName": "claude-sonnet-5", "inputTokens": 200, "outputTokens": 100, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 20.0}
      ],
      "metadata": {"agents": ["claude"]}
    }
  ],
  "totals": {"inputTokens": 300, "outputTokens": 150, "cacheCreationTokens": 10, "cacheReadTokens": 5, "totalTokens": 465, "totalCost": 32.5}
}
EOF

cat >"$tmp/macbook.json" <<'EOF'
{
  "monthly": [
    {
      "agent": "all", "period": "2026-07",
      "inputTokens": 10, "outputTokens": 5, "cacheCreationTokens": 0, "cacheReadTokens": 0,
      "totalTokens": 15, "totalCost": 1.0,
      "modelsUsed": ["grok-4.6-build"],
      "modelBreakdowns": [
        {"modelName": "grok-4.6-build", "inputTokens": 10, "outputTokens": 5, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1.0}
      ],
      "metadata": {"agents": ["grok"]}
    },
    {
      "agent": "all", "period": "2026-08",
      "inputTokens": 40, "outputTokens": 20, "cacheCreationTokens": 0, "cacheReadTokens": 2,
      "totalTokens": 62, "totalCost": 5.0,
      "modelsUsed": ["gpt-6-astra"],
      "modelBreakdowns": [
        {"modelName": "gpt-6-astra", "inputTokens": 40, "outputTokens": 20, "cacheCreationTokens": 0, "cacheReadTokens": 2, "cost": 5.0}
      ],
      "metadata": {"agents": ["codex"]}
    }
  ],
  "totals": {"inputTokens": 50, "outputTokens": 25, "cacheCreationTokens": 0, "cacheReadTokens": 2, "totalTokens": 77, "totalCost": 6.0}
}
EOF

# A --by-agent pair, same period, one overlapping agent (claude) and one agent
# ("pi") that only the second machine has.
cat >"$tmp/mini-agent.json" <<'EOF'
{
  "monthly": [
    {
      "agent": "all", "period": "2026-09",
      "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 0, "cacheReadTokens": 0,
      "totalTokens": 150, "totalCost": 10.0,
      "modelsUsed": ["claude-sonnet-5"],
      "modelBreakdowns": [
        {"modelName": "claude-sonnet-5", "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 10.0}
      ],
      "metadata": {"agents": ["claude"]},
      "agents": [
        {
          "agent": "claude",
          "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 0, "cacheReadTokens": 0,
          "totalTokens": 150, "totalCost": 10.0,
          "modelsUsed": ["claude-sonnet-5"],
          "modelBreakdowns": [
            {"modelName": "claude-sonnet-5", "inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 10.0}
          ]
        }
      ]
    }
  ],
  "totals": {"inputTokens": 100, "outputTokens": 50, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 150, "totalCost": 10.0}
}
EOF

cat >"$tmp/macbook-agent.json" <<'EOF'
{
  "monthly": [
    {
      "agent": "all", "period": "2026-09",
      "inputTokens": 30, "outputTokens": 15, "cacheCreationTokens": 0, "cacheReadTokens": 0,
      "totalTokens": 45, "totalCost": 3.0,
      "modelsUsed": ["claude-sonnet-5", "[pi] gpt-6-astra"],
      "modelBreakdowns": [
        {"modelName": "claude-sonnet-5", "inputTokens": 10, "outputTokens": 5, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1.0},
        {"modelName": "[pi] gpt-6-astra", "inputTokens": 20, "outputTokens": 10, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 2.0}
      ],
      "metadata": {"agents": ["claude", "pi"]},
      "agents": [
        {
          "agent": "claude",
          "inputTokens": 10, "outputTokens": 5, "cacheCreationTokens": 0, "cacheReadTokens": 0,
          "totalTokens": 15, "totalCost": 1.0,
          "modelsUsed": ["claude-sonnet-5"],
          "modelBreakdowns": [
            {"modelName": "claude-sonnet-5", "inputTokens": 10, "outputTokens": 5, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 1.0}
          ]
        },
        {
          "agent": "pi",
          "inputTokens": 20, "outputTokens": 10, "cacheCreationTokens": 0, "cacheReadTokens": 0,
          "totalTokens": 30, "totalCost": 2.0,
          "modelsUsed": ["[pi] gpt-6-astra"],
          "modelBreakdowns": [
            {"modelName": "[pi] gpt-6-astra", "inputTokens": 20, "outputTokens": 10, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 2.0}
          ]
        }
      ]
    }
  ],
  "totals": {"inputTokens": 30, "outputTokens": 15, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 45, "totalCost": 3.0}
}
EOF

cat >"$tmp/daily.json" <<'EOF'
{
  "daily": [
    {
      "agent": "all", "period": "2026-09-10",
      "inputTokens": 1, "outputTokens": 1, "cacheCreationTokens": 0, "cacheReadTokens": 0,
      "totalTokens": 2, "totalCost": 0.1,
      "modelsUsed": ["claude-sonnet-5"],
      "modelBreakdowns": [
        {"modelName": "claude-sonnet-5", "inputTokens": 1, "outputTokens": 1, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.1}
      ],
      "metadata": {"agents": ["claude"]}
    }
  ],
  "totals": {"inputTokens": 1, "outputTokens": 1, "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 2, "totalCost": 0.1}
}
EOF

cp "$tmp/mini.json" "$tmp/mini-bogus-top.json"
python3 -c "
import json
d = json.load(open('$tmp/mini-bogus-top.json'))
d['bogus'] = 1
json.dump(d, open('$tmp/mini-bogus-top.json', 'w'))
"

cp "$tmp/mini.json" "$tmp/mini-bogus-row.json"
python3 -c "
import json
d = json.load(open('$tmp/mini-bogus-row.json'))
d['monthly'][0]['bogusRowKey'] = 1
json.dump(d, open('$tmp/mini-bogus-row.json', 'w'))
"

cp "$tmp/mini.json" "$tmp/mini-session.json"
python3 -c "
import json
d = json.load(open('$tmp/mini-session.json'))
d['session'] = d.pop('monthly')
json.dump(d, open('$tmp/mini-session.json', 'w'))
"

# Derived fixtures: blocks shape, totals that disagree with the rows, newest-first
# copies (--order desc), and a one-row daily report for another day.
python3 - "$tmp" <<'PY'
import copy, json, sys
t = sys.argv[1]
load = lambda name: json.load(open(f"{t}/{name}.json"))
def save(name, d):
    json.dump(d, open(f"{t}/{name}.json", "w"))
d = load("mini"); d["blocks"] = d.pop("monthly"); save("mini-blocks", d)
d = load("mini"); d["totals"]["totalTokens"] += 1; save("mini-bad-totals", d)
for name in ("mini", "macbook"):
    d = load(name); d["monthly"].reverse(); save(f"{name}-desc", d)
d = load("daily"); d["daily"][0]["period"] = "2026-09-09"; save("daily2", d)
d = load("mini-agent"); d["monthly"][0]["agents"][0]["period"] = "x"; save("bogus-nested", d)
d = load("mini"); d["monthly"][0]["modelBreakdowns"][0]["bogus"] = 1; save("bogus-breakdown", d)
d = load("mini"); del d["totals"]["totalCost"]; save("short-totals", d)
PY

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# 1. Sums two reports by period; non-overlapping periods pass through untouched;
#    overlapping period adds; rows stay sorted by period.
out="$(python3 "$script" "$tmp/mini.json" "$tmp/macbook.json" 2>"$tmp/err")"
if [ -n "$out" ]; then
  periods="$(get '[r["period"] for r in d["monthly"]]' "$out")"
  [ "$periods" = "['2026-07', '2026-08', '2026-09']" ] && pass "rows sorted by period, non-overlapping periods kept" \
    || bad "rows sorted by period, non-overlapping periods kept (got: $periods)"

  aug_input="$(get 'next(r["inputTokens"] for r in d["monthly"] if r["period"]=="2026-08")' "$out")"
  [ "$aug_input" = "140" ] && pass "overlapping period sums inputTokens (100+40=140)" \
    || bad "overlapping period sums inputTokens (want 140, got $aug_input)"

  aug_cache_read="$(get 'next(r["cacheReadTokens"] for r in d["monthly"] if r["period"]=="2026-08")' "$out")"
  [ "$aug_cache_read" = "7" ] && pass "overlapping period sums cacheReadTokens (5+2=7)" \
    || bad "overlapping period sums cacheReadTokens (want 7, got $aug_cache_read)"

  aug_models="$(get 'sorted(next(r["modelsUsed"] for r in d["monthly"] if r["period"]=="2026-08"))' "$out")"
  [ "$aug_models" = "['claude-sonnet-5', 'gpt-6-astra']" ] && pass "modelsUsed becomes a sorted union" \
    || bad "modelsUsed becomes a sorted union (got: $aug_models)"

  aug_agents="$(get 'sorted(next(r["metadata"]["agents"] for r in d["monthly"] if r["period"]=="2026-08"))' "$out")"
  [ "$aug_agents" = "['claude', 'codex']" ] && pass "metadata.agents becomes a sorted union" \
    || bad "metadata.agents becomes a sorted union (got: $aug_agents)"

  gpt_breakdown="$(get 'next(m for m in next(r["modelBreakdowns"] for r in d["monthly"] if r["period"]=="2026-08") if m["modelName"]=="gpt-6-astra")' "$out")"
  gpt_input="$(get 'next(m for m in next(r["modelBreakdowns"] for r in d["monthly"] if r["period"]=="2026-08") if m["modelName"]=="gpt-6-astra")["inputTokens"]' "$out")"
  gpt_cost="$(get 'round(next(m for m in next(r["modelBreakdowns"] for r in d["monthly"] if r["period"]=="2026-08") if m["modelName"]=="gpt-6-astra")["cost"], 2)' "$out")"
  [ "$gpt_input" = "80" ] && [ "$gpt_cost" = "9.5" ] && pass "modelBreakdowns add per modelName (40+40=80, 4.5+5.0=9.5)" \
    || bad "modelBreakdowns add per modelName (got input=$gpt_input cost=$gpt_cost)"

  recomputed_cost="$(get 'round(d["totals"]["totalCost"], 2)' "$out")"
  [ "$recomputed_cost" = "38.5" ] && pass "totals equal the sum of the two inputs' totals (32.5+6.0=38.5)" \
    || bad "totals equal the sum of the two inputs' totals (got $recomputed_cost)"
else
  bad "sum two reports by period (script produced no output: $(cat "$tmp/err"))"
fi

# 2. A --by-agent pair: nested agents[] merge per agent, an agent unique to one
#    side is kept untouched, the top row's own numbers still add.
out="$(python3 "$script" "$tmp/mini-agent.json" "$tmp/macbook-agent.json" 2>"$tmp/err")"
if [ -n "$out" ]; then
  top_input="$(get 'd["monthly"][0]["inputTokens"]' "$out")"
  [ "$top_input" = "130" ] && pass "--by-agent: top row still sums (100+30=130)" \
    || bad "--by-agent: top row still sums (got $top_input)"

  claude_input="$(get 'next(a for a in d["monthly"][0]["agents"] if a["agent"]=="claude")["inputTokens"]' "$out")"
  [ "$claude_input" = "110" ] && pass "--by-agent: nested agents[] merge per agent (claude 100+10=110)" \
    || bad "--by-agent: nested agents[] merge per agent (got $claude_input)"

  pi_input="$(get 'next(a for a in d["monthly"][0]["agents"] if a["agent"]=="pi")["inputTokens"]' "$out")"
  [ "$pi_input" = "20" ] && pass "--by-agent: agent unique to one side is kept as-is (pi=20)" \
    || bad "--by-agent: agent unique to one side is kept as-is (got $pi_input)"

  agent_names="$(get 'sorted(a["agent"] for a in d["monthly"][0]["agents"])' "$out")"
  [ "$agent_names" = "['claude', 'pi']" ] && pass "--by-agent: nested agent set is the union" \
    || bad "--by-agent: nested agent set is the union (got $agent_names)"
else
  bad "merge a --by-agent pair (script produced no output: $(cat "$tmp/err"))"
fi

# 3. One input comes back with the same rows and totals.
out="$(python3 "$script" "$tmp/mini.json" 2>"$tmp/err")"
if [ -n "$out" ] && python3 -c '
import json, sys
a, b = json.loads(sys.argv[1]), json.load(open(sys.argv[2]))
sys.exit(not (a["monthly"] == b["monthly"] and a["totals"] == b["totals"]))' "$out" "$tmp/mini.json"; then
  pass "one input: same rows and totals"
else
  bad "one input: same rows and totals (got: $out $(cat "$tmp/err"))"
fi

# 3b. Row order follows the inputs: newest first only when every input with two or
#     more rows is newest first; otherwise (or when no input shows an order) oldest first.
order() { python3 "$script" "$@" 2>"$tmp/err" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(r["period"] for r in next(v for k, v in d.items() if k != "totals")))'; }
[ "$(order "$tmp/mini-desc.json" "$tmp/macbook-desc.json")" = "2026-09 2026-08 2026-07" ] \
  && pass "newest-first inputs stay newest first" || bad "newest-first inputs stay newest first"
[ "$(order "$tmp/mini.json" "$tmp/macbook-desc.json")" = "2026-07 2026-08 2026-09" ] \
  && pass "mixed input order: oldest first" || bad "mixed input order: oldest first"
[ "$(order "$tmp/daily.json" "$tmp/daily2.json")" = "2026-09-09 2026-09-10" ] \
  && pass "one-row inputs: oldest first" || bad "one-row inputs: oldest first"

# 4. Refusals.
python3 "$script" "$tmp/mini.json" "$tmp/daily.json" >"$tmp/out" 2>"$tmp/err"
refused "mismatched report kinds (monthly + daily) refused" "$?" "$tmp/err"

python3 "$script" "$tmp/mini-bad-totals.json" "$tmp/macbook.json" >"$tmp/out" 2>"$tmp/err"
refused "totals that disagree with the rows refused" "$?" "$tmp/err"

python3 "$script" "$tmp/mini-blocks.json" >"$tmp/out" 2>"$tmp/err"
refused "blocks report refused" "$?" "$tmp/err"

python3 "$script" "$tmp/bogus-nested.json" "$tmp/macbook-agent.json" >"$tmp/out" 2>"$tmp/err"
refused "unknown nested agent key refused" "$?" "$tmp/err"

python3 "$script" "$tmp/bogus-breakdown.json" "$tmp/macbook.json" >"$tmp/out" 2>"$tmp/err"
refused "unknown modelBreakdowns key refused" "$?" "$tmp/err"

python3 "$script" "$tmp/short-totals.json" "$tmp/macbook.json" >"$tmp/out" 2>"$tmp/err"
refused "totals missing a key refused" "$?" "$tmp/err"
grep -q "missing key(s) \['totalCost'\]" "$tmp/err" && pass "totals missing a key: the key is named" \
  || bad "totals missing a key: the key is named (stderr: $(cat "$tmp/err"))"

python3 "$script" "$tmp/mini-bogus-top.json" "$tmp/macbook.json" >"$tmp/out" 2>"$tmp/err"
refused "unknown top-level key refused" "$?" "$tmp/err"

python3 "$script" "$tmp/mini-bogus-row.json" "$tmp/macbook.json" >"$tmp/out" 2>"$tmp/err"
refused "unknown row-level key refused" "$?" "$tmp/err"

python3 "$script" "$tmp/mini-session.json" >"$tmp/out" 2>"$tmp/err"
refused "session report refused" "$?" "$tmp/err"

python3 "$script" >"$tmp/out" 2>"$tmp/err"
refused "no input files refused" "$?" "$tmp/err"

if (( failures > 0 )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all merge-reports checks passed"
