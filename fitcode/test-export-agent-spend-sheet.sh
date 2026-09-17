#!/usr/bin/env bash
# Self-test for export-agent-spend-sheet.py payload shape and privacy.
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

cat >"$tmp/cursor.json" <<'EOF'
{
  "days": [
    {"date": "2025-07-06", "charged_usd": 3.0, "list_usd": 3.8, "events": 2, "models": {"gpt-5": 2}},
    {"date": "2026-09-10", "charged_usd": 0.0, "list_usd": 0.0869, "events": 1, "models": {"composer-2.5": 1}}
  ],
  "months": [
    {"month": "2025-07", "charged_usd": 3.0, "list_usd": 3.8, "events": 2, "models": {"gpt-5": 2}},
    {"month": "2026-09", "charged_usd": 0.0, "list_usd": 0.0869, "events": 1, "models": {"composer-2.5": 1}}
  ],
  "totals": {"charged_usd": 3.0, "list_usd": 3.8869, "events": 3}
}
EOF
cat >"$tmp/fleet.json" <<'EOF'
{
  "monthly": [
    {"period": "2026-09", "totalCost": 14931.48, "totalTokens": 100, "metadata": {"agents": ["claude", "jcode"]}}
  ],
  "totals": {"totalCost": 14931.48, "totalTokens": 100}
}
EOF

out="$(python3 "$script" --cursor-json "$tmp/cursor.json" --fleet-json "$tmp/fleet.json" --json)"
ranges="$(get '[x["range"] for x in d]' "$out")"
python3 -c "import sys; sys.exit(0 if 'Read me' in '''$ranges''' and 'Cursor monthly' in '''$ranges''' else 1)" \
  && pass "payload has Read me and Cursor monthly ranges" \
  || bad "payload ranges (got $ranges)"

july="$(get 'next(r["values"] for r in d if "Cursor monthly" in r["range"])[1][0]' "$out")"
[ "$july" = "2025-07" ] && pass "monthly table starts with 2025-07" || bad "monthly first row (got $july)"

charged="$(get 'next(r["values"] for r in d if "Cursor monthly" in r["range"])[1][1]' "$out")"
[ "$charged" = "3.0" ] && pass "monthly charged_usd copied" || bad "monthly charged (got $charged)"

if printf '%s' "$out" | grep -qi 'secret@example.com'; then
  bad "payload omits emails"
else
  pass "payload omits emails"
fi

fleet_total="$(get 'next(r["values"] for r in d if "Fleet monthly" in r["range"])[-1][1]' "$out")"
[ "$fleet_total" = "14931.48" ] && pass "fleet totalCost lands on TOTAL row" || bad "fleet total (got $fleet_total)"

mut="$tmp/mutant.py"
python3 - "$script" "$mut" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
old = 'str(row.get("charged_usd", ""))'
if old not in src:
    raise SystemExit("mutant seed missing")
pathlib.Path(sys.argv[2]).write_text(src.replace(old, '"999"', 1))
PY
mout="$(python3 "$mut" --cursor-json "$tmp/cursor.json" --json)"
mch="$(get 'next(r["values"] for r in d if "Cursor monthly" in r["range"])[1][1]' "$mout")"
[ "$mch" = "999" ] && pass "break-test: swapping charged_usd is detected" || bad "break-test charged (got $mch)"

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "$passes checks passed"
exit 0
