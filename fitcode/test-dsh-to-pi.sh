#!/usr/bin/env bash
# Self-test for dsh-to-pi.py: assistant/message counts, chunks do not.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
script="${DSH_TO_PI:-$here/dsh-to-pi.py}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
passes=0
pass() { echo "ok   $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

sess="$tmp/sessions/proj/session-abc"
mkdir -p "$sess"
cat >"$sess/session.jsonl" <<'EOF'
{"type":"assistant/chunk","time":1751842936879,"data":{"chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":5,"totalTokens":105,"cacheReadTokens":0}}}}
{"type":"assistant/message","time":1751842936879,"data":{"message":{"role":"assistant","source":{"provider":"xai","model":"grok-4.6"}},"usage":{"inputTokens":100,"outputTokens":5,"totalTokens":105,"cacheReadTokens":0}}}
EOF

out="$tmp/out"
python3 "$script" --out "$out" --sessions "$tmp/sessions"
n="$(find "$out" -name '*.jsonl' | wc -l | tr -d ' ')"
[ "$n" = "1" ] && pass "one session file written" || bad "one session file (got $n)"
lines="$(wc -l <"$out"/*.jsonl | tr -d ' ')"
[ "$lines" = "1" ] && pass "chunk is ignored; one usage line" || bad "line count (got $lines)"

model="$(python3 -c 'import json,glob; print(json.loads(open(glob.glob("'"$out"'/*.jsonl")[0]).readline())["message"]["model"])')"
[ "$model" = "grok-4.6" ] && pass "model grok-4.6" || bad "model (got $model)"

ts="$(python3 -c 'import json,glob; print(json.loads(open(glob.glob("'"$out"'/*.jsonl")[0]).readline())["timestamp"])')"
python3 -c "import sys; sys.exit(0 if '$ts'.endswith('Z') and '.$ts'.count('.')>=1 else 1)" \
  && pass "timestamp is RFC3339 with millis" \
  || bad "timestamp (got $ts)"

python3 "$script" --out "$tmp/none" --sessions "$tmp/missing-dir"
[ $? -eq 0 ] && pass "missing sessions dir exits 0" || bad "missing dir"

mut="$tmp/mutant.py"
python3 - "$script" "$mut" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text()
old = 'if obj.get("type") != "assistant/message":'
if old not in src:
    raise SystemExit("mutant seed missing")
pathlib.Path(sys.argv[2]).write_text(src.replace(old, 'if obj.get("type") != "assistant/chunk":', 1))
PY
mout="$tmp/mutout"
python3 "$mut" --out "$mout" --sessions "$tmp/sessions"
mlines="$(wc -l <"$mout"/*.jsonl | tr -d ' ')"
[ "$mlines" != "1" ] && pass "break-test: counting chunks changes line count" || bad "break-test still 1 line"

if [ "$failures" -ne 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "$passes checks passed"
exit 0
