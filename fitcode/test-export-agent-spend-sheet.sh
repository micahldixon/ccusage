#!/usr/bin/env bash
# Self-test: Master grain includes Cursor; Dashboard prune calls; Combined spend adds.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${EXPORT_AGENT_SPEND_SHEET:-$here/export-agent-spend-sheet.py}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
passes=0
pass() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

get() {
  python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
" <<<"$2"
}

cat >"$tmp/mini.json" <<'EOF'
{
  "monthly": [
    {
      "period": "2026-08",
      "totalCost": 40.0,
      "agents": [{"agent": "claude", "totalCost": 40.0, "modelBreakdowns": [{"modelName": "claude-opus-5", "cost": 40.0}]}]
    },
    {
      "period": "2026-09",
      "totalCost": 50.0,
      "agents": [{"agent": "claude", "totalCost": 50.0, "modelBreakdowns": [{"modelName": "claude-opus-5", "cost": 50.0}]}]
    }
  ],
  "totals": {"totalCost": 90.0}
}
EOF
cat >"$tmp/macbook.json" <<'EOF'
{
  "monthly": [
    {
      "period": "2026-09",
      "totalCost": 2.0,
      "agents": [{"agent": "copilot", "totalCost": 2.0, "modelBreakdowns": [{"modelName": "gpt-4o", "cost": 2.0}]}]
    }
  ],
  "totals": {"totalCost": 2.0}
}
EOF
cat >"$tmp/cursor.json" <<'EOF'
{
  "by_month_model": [
    {"month": "2026-09", "model": "claude-4.6-sonnet-high-thinking", "charged_usd": 10.0, "list_usd": 12.0, "events": 2}
  ],
  "totals": {"charged_usd": 10.0, "list_usd": 12.0, "events": 2}
}
EOF

out="$(python3 "$script" --mini-json "$tmp/mini.json" --macbook-json "$tmp/macbook.json" --cursor-json "$tmp/cursor.json" --json)"

tabs="$(get '[x["range"] for x in d]' "$out")"
python3 -c "import sys; t='''$tabs'''; sys.exit(0 if 'Dashboard!A1' in t and 'Master!A1' in t else 1)" \
  && pass "payload has Dashboard and Master" \
  || bad "tabs (got $tabs)"

python3 -c "import sys; t='''$tabs'''; sys.exit(0 if 'Family!' not in t and 'Cursor!' not in t else 1)" \
  && pass "no Family or Cursor ghetto tabs" \
  || bad "old tabs still present ($tabs)"

master="$(get 'next(r["values"] for r in d if r["range"].startswith("Master"))' "$out")"
python3 - <<PY
import ast, sys
m = ast.literal_eval('''$master''')
body = m[1:]
spend = round(sum(float(r[6]) for r in body), 2)
cursor = [r for r in body if r[2]=="cursor"]
sys.exit(0 if spend==102.0 and cursor and cursor[0][1]=="account" else 1)
PY
if [ $? -eq 0 ]; then
  pass "Master spend is 90+2+10=102 and Cursor is machine=account"
else
  bad "Master spend/cursor grain"
fi

shop="$(get 'next(row[1] for row in next(r["values"] for r in d if r["range"]=="Dashboard!A1") if row and row[0]=="Shop total")' "$out")"
[ "$shop" = "102.0" ] && pass "Dashboard shop total is 102" || bad "shop (got $shop)"

call_copilot="$(get 'next(row[4] for row in next(r["values"] for r in d if r["range"]=="Dashboard!A1") if row and row[0]=="copilot")' "$out")"
[ "$call_copilot" = "Cut candidate" ] && pass "copilot is Cut candidate" || bad "copilot call (got $call_copilot)"

call_claude="$(get 'next(row[4] for row in next(r["values"] for r in d if r["range"]=="Dashboard!A1") if row and row[0]=="claude")' "$out")"
[ "$call_claude" = "Keep" ] && pass "claude is Keep" || bad "claude call (got $call_claude)"

if printf '%s' "$out" | grep -qi 'secret@example.com'; then
  bad "payload omits emails"
else
  pass "payload omits emails"
fi

mut="$tmp/mutant.py"
python3 - "$script" "$mut" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
old = 'rows.append([period, machine, source, family, model, effort, usd])'
if old not in src:
    raise SystemExit("mutant seed missing")
# drop cursor rows
src2 = src.replace(
    'rows.append(\n                [\n                    str(item.get("month") or ""),\n                    "account",\n                    "cursor",',
    'if False: rows.append(\n                [\n                    str(item.get("month") or ""),\n                    "account",\n                    "cursor",',
    1,
)
pathlib.Path(sys.argv[2]).write_text(src2)
PY
mout="$(python3 "$mut" --mini-json "$tmp/mini.json" --macbook-json "$tmp/macbook.json" --cursor-json "$tmp/cursor.json" --json 2>/dev/null || true)"
mshop="$(get 'next(row[1] for row in next(r["values"] for r in d if r["range"]=="Dashboard!A1") if row and row[0]=="Shop total")' "$mout" 2>/dev/null || echo fail)"
python3 -c "import sys; sys.exit(0 if '$mshop'!='102.0' else 1)" \
  && pass "break-test: dropping Cursor from Master changes shop total" \
  || bad "break-test shop still 102 (got $mshop)"

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "$passes checks passed"
exit 0
