#!/usr/bin/env bash
# Self-test for cursor-usage.py. Feeds fixture Cursor usage events and fails if
# the aggregator stops following a money, date, or privacy rule.
#
# CURSOR_USAGE can point this test at a different copy of the script (used to
# prove each check can actually fail, by running it against a deliberately
# broken copy).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${CURSOR_USAGE:-$here/cursor-usage.py}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
passes=0

pass() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

refused() {
  local label="$1" rc="$2" errfile="$3"
  if [ "$rc" -ne 0 ] && grep -q '^cursor-usage: ' "$errfile"; then
    pass "$label"
  else
    bad "$label (exit $rc, stderr: $(cat "$errfile"))"
  fi
}

get() {
  python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
" <<<"$2"
}

cat >"$tmp/events.json" <<'EOF'
[
  {
    "timestamp": "1751842936879",
    "model": "gpt-5",
    "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
    "chargedCents": 250,
    "tokenUsage": {"inputTokens": 1000, "outputTokens": 50, "totalCents": 300},
    "owningUser": "secret@example.com",
    "isChargeable": true,
    "isTokenBasedCall": true
  },
  {
    "timestamp": "1751842936879",
    "model": "gpt-5",
    "kind": "USAGE_EVENT_KIND_INCLUDED_IN_PRO",
    "chargedCents": 50,
    "tokenUsage": {"totalCents": 80},
    "owningUser": "secret@example.com",
    "isChargeable": true
  },
  {
    "timestamp": "2026-09-10T12:00:00.000Z",
    "model": "composer-2.5",
    "kind": "USAGE_EVENT_KIND_FREE_CREDIT",
    "chargedCents": 0,
    "tokenUsage": {"totalCents": 8.69},
    "owningUser": "secret@example.com",
    "isChargeable": false
  }
]
EOF

out="$(python3 "$script" --events-json "$tmp/events.json" --json 2>"$tmp/err")"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "fixture run exits 0"
else
  bad "fixture run exits 0 (exit $rc, stderr: $(cat "$tmp/err"))"
  echo "$failures failed"
  exit 1
fi

charged="$(get 'd["totals"]["charged_usd"]' "$out")"
list="$(get 'd["totals"]["list_usd"]' "$out")"
events="$(get 'd["totals"]["events"]' "$out")"
python3 -c "
import sys
charged=float('$charged'); list_usd=float('$list'); events=int('$events')
sys.exit(0 if abs(charged-3.0)<1e-9 and abs(list_usd-3.8869)<1e-9 and events==3 else 1)
" && pass "totals use cents/100, not raw cents or dollars" || bad "totals use cents/100 (charged=$charged list=$list events=$events)"

days="$(get 'len(d["days"])' "$out")"
[ "$days" = "2" ] && pass "two UTC days" || bad "two UTC days (got $days)"

d1="$(get 'sorted(d["days"], key=lambda x: x["date"])[0]["date"]' "$out")"
d2="$(get 'sorted(d["days"], key=lambda x: x["date"])[1]["date"]' "$out")"
[ "$d1" = "2025-07-06" ] && pass "ms timestamp becomes 2025-07-06 UTC" || bad "ms timestamp date (got $d1)"
[ "$d2" = "2026-09-10" ] && pass "ISO timestamp becomes 2026-09-10 UTC" || bad "ISO timestamp date (got $d2)"

july_charged="$(get 'sorted(d["days"], key=lambda x: x["date"])[0]["charged_usd"]' "$out")"
python3 -c "import sys; sys.exit(0 if abs(float('$july_charged')-3.0)<1e-9 else 1)" \
  && pass "July day charged is sum of that day's events" \
  || bad "July day charged (got $july_charged)"

free_charged="$(get 'sorted(d["days"], key=lambda x: x["date"])[1]["charged_usd"]' "$out")"
free_list="$(get 'sorted(d["days"], key=lambda x: x["date"])[1]["list_usd"]' "$out")"
python3 -c "import sys; sys.exit(0 if abs(float('$free_charged'))<1e-12 and abs(float('$free_list')-0.0869)<1e-9 else 1)" \
  && pass "free-credit events stay in the list total at \$0 charged" \
  || bad "free-credit (charged=$free_charged list=$free_list)"

day_sum="$(get 'round(sum(x["charged_usd"] for x in d["days"]), 6)' "$out")"
python3 -c "import sys; sys.exit(0 if abs(float('$day_sum')-float('$charged'))<1e-9 else 1)" \
  && pass "day charged sums to totals" \
  || bad "day charged sums to totals (days=$day_sum totals=$charged)"

months="$(get 'len(d["months"])' "$out")"
[ "$months" = "2" ] && pass "two months" || bad "two months (got $months)"

gpt_charged="$(get 'next(m["charged_usd"] for m in d["by_model"] if m["model"]=="gpt-5")' "$out")"
python3 -c "import sys; sys.exit(0 if abs(float('$gpt_charged')-3.0)<1e-9 else 1)" \
  && pass "by_model gpt-5 charged is \$3.00" \
  || bad "by_model gpt-5 (got $gpt_charged)"

gpt_month="$(get 'next(m["charged_usd"] for m in d["by_month_model"] if m["month"]=="2025-07" and m["model"]=="gpt-5")' "$out")"
python3 -c "import sys; sys.exit(0 if abs(float('$gpt_month')-3.0)<1e-9 else 1)" \
  && pass "by_month_model gpt-5 in 2025-07 is \$3.00" \
  || bad "by_month_model (got $gpt_month)"

if printf '%s' "$out" | grep -qi 'secret@example.com'; then
  bad "output omits owningUser email"
else
  pass "output omits owningUser email"
fi

python3 "$script" --json >/dev/null 2>"$tmp/err"
refused "refuses without --events-json or --live" "$?" "$tmp/err"

mut="$tmp/mutant.py"
python3 - "$script" "$mut" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
old = 'float(tu.get("totalCents") or tu.get("total_cents") or 0) / 100.0'
if old not in src:
    raise SystemExit("mutant seed missing")
pathlib.Path(sys.argv[2]).write_text(src.replace(old, old.replace(" / 100.0", ""), 1))
PY
mout="$(python3 "$mut" --events-json "$tmp/events.json" --json)"
mlist="$(get 'd["totals"]["list_usd"]' "$mout")"
python3 -c "import sys; sys.exit(0 if abs(float('$mlist')-3.8869)>0.5 else 1)" \
  && pass "break-test: skipping /100 changes list_usd" \
  || bad "break-test: skipping /100 should change list_usd (got $mlist)"

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "$passes checks passed"
exit 0
