#!/usr/bin/env bash
# Self-test for jcode-to-pi.py. Builds inline fixture jcode session files (.json,
# .journal.jsonl, .bak) covering every conversion rule and refusal, and fails if
# the script stops handling any of them.
#
# JCODE_TO_PI can point this test at a different copy of the script (used to
# prove each check can actually fail, by running it against a deliberately
# broken copy).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${JCODE_TO_PI:-$here/jcode-to-pi.py}"
repo_root="$(cd "$here/.." && pwd)"
ccusage_bin="$repo_root/rust/target/release/ccusage"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

pass() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failures=$((failures + 1)); }

# get JSON JQ_LIKE_PYTHON_EXPR — evaluate a python expression against JSON on stdin
get() {
  python3 -c "
import json, sys
d = json.load(sys.stdin)
print($1)
" <<<"$2"
}

# lines FILE — print a jsonl file's lines each parsed back into a python dict,
# one per line, so checks can pick fields out of them.
line_field() {
  # line_field FILE INDEX PYEXPR (PYEXPR sees `d` = parsed line INDEX, 0-based)
  python3 -c "
import json
lines = [l for l in open('$1') if l.strip()]
d = json.loads(lines[$2])
print($3)
"
}

n_lines() {
  [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || echo 0
}

run_convert() {
  # run_convert SESSIONS_DIR OUT_DIR [extra args...]
  local sdir="$1" odir="$2"
  shift 2
  python3 "$script" --out "$odir" --sessions "$sdir" "$@"
}

# ---------------------------------------------------------------------------
# 1. Basic Claude-provider session: input unchanged, cacheRead/cacheWrite mapped,
#    totalTokens computed, timestamp truncated to 3 fractional digits.
# ---------------------------------------------------------------------------
s1="$tmp/s1/sessions"
mkdir -p "$s1"
cat >"$s1/session_basic.json" <<'EOF'
{
  "id": "session_basic",
  "model": "claude-fable-5",
  "provider_key": "claude-oauth",
  "messages": [
    {
      "id": "m1",
      "role": "assistant",
      "timestamp": "2026-09-10T12:00:00.123456Z",
      "token_usage": {
        "input_tokens": 1000,
        "output_tokens": 50,
        "cache_read_input_tokens": 41253,
        "cache_creation_input_tokens": 10
      }
    },
    {
      "id": "m1-user",
      "role": "user",
      "timestamp": "2026-09-10T12:00:00.000000Z",
      "token_usage": {
        "input_tokens": 777777,
        "output_tokens": 777,
        "cache_read_input_tokens": 0
      }
    }
  ]
}
EOF
out1="$tmp/out1"
run_convert "$s1" "$out1" >"$tmp/err1" 2>&1
outfile="$out1/session_basic.jsonl"
if [ -f "$outfile" ]; then
  n="$(n_lines "$outfile")"
  # The user-role message above carries its own non-zero token_usage, so this
  # only passes if the role check actually runs -- an "if not tu: continue"
  # alone would not have filtered it out.
  [ "$n" = "1" ] && pass "one line written per assistant token_usage message (user message with its own token_usage skipped)" \
    || bad "one line written per assistant token_usage message (got $n lines)"

  ts="$(line_field "$outfile" 0 'd["timestamp"]')"
  [ "$ts" = "2026-09-10T12:00:00.123Z" ] && pass "timestamp truncated to 3 fractional digits" \
    || bad "timestamp truncated to 3 fractional digits (got $ts)"

  inp="$(line_field "$outfile" 0 'd["message"]["usage"]["input"]')"
  [ "$inp" = "1000" ] && pass "claude provider: input_tokens unchanged" \
    || bad "claude provider: input_tokens unchanged (got $inp)"

  cr="$(line_field "$outfile" 0 'd["message"]["usage"]["cacheRead"]')"
  [ "$cr" = "41253" ] && pass "cache_read_input_tokens -> cacheRead" \
    || bad "cache_read_input_tokens -> cacheRead (got $cr)"

  cw="$(line_field "$outfile" 0 'd["message"]["usage"]["cacheWrite"]')"
  [ "$cw" = "10" ] && pass "cache_creation_input_tokens -> cacheWrite" \
    || bad "cache_creation_input_tokens -> cacheWrite (got $cw)"

  tot="$(line_field "$outfile" 0 'd["message"]["usage"]["totalTokens"]')"
  [ "$tot" = "42313" ] && pass "totalTokens = input+output+cacheRead+cacheWrite (1000+50+41253+10=42313)" \
    || bad "totalTokens sums the four fields (got $tot)"

  model="$(line_field "$outfile" 0 'd["message"]["model"]')"
  [ "$model" = "claude-fable-5" ] && pass "model taken from session level" \
    || bad "model taken from session level (got $model)"

  role="$(line_field "$outfile" 0 'd["message"]["role"]')"
  [ "$role" = "assistant" ] && pass "role is assistant" || bad "role is assistant (got $role)"

  no_cost="$(line_field "$outfile" 0 '"cost" in d["message"]')"
  [ "$no_cost" = "False" ] && pass "no cost field is written" || bad "no cost field is written (got $no_cost)"
else
  bad "basic claude session produces output ($outfile missing; stderr: $(cat "$tmp/err1"))"
fi

# ---------------------------------------------------------------------------
# 2. OpenAI-provider cache-inclusive rule: input = input_tokens - cache_read
#    ONLY (cache_creation_input_tokens is NOT subtracted, only mapped to
#    cacheWrite) -- this is the exact wording of the rule, distinct from
#    subtracting both cache fields.
# ---------------------------------------------------------------------------
s2="$tmp/s2/sessions"
mkdir -p "$s2"
cat >"$s2/session_oa.json" <<'EOF'
{
  "id": "session_oa",
  "model": "gpt-5.6-sol",
  "provider_key": "openai-oauth",
  "messages": [
    {
      "id": "oa1",
      "role": "assistant",
      "timestamp": "2026-09-10T12:00:00.500000Z",
      "token_usage": {
        "input_tokens": 100000,
        "output_tokens": 500,
        "cache_read_input_tokens": 90000,
        "cache_creation_input_tokens": 3000
      }
    }
  ]
}
EOF
out2="$tmp/out2"
run_convert "$s2" "$out2" >"$tmp/err2" 2>&1
outfile="$out2/session_oa.jsonl"
if [ -f "$outfile" ]; then
  inp="$(line_field "$outfile" 0 'd["message"]["usage"]["input"]')"
  # 100000 - 90000 = 10000 (cache_creation_input_tokens is NOT subtracted)
  [ "$inp" = "10000" ] && pass "openai-oauth: input = input_tokens - cache_read only (100000-90000=10000)" \
    || bad "openai-oauth: input = input_tokens - cache_read only (got $inp, want 10000)"

  cw="$(line_field "$outfile" 0 'd["message"]["usage"]["cacheWrite"]')"
  [ "$cw" = "3000" ] && pass "openai-oauth: cache_creation_input_tokens still mapped to cacheWrite (not subtracted twice)" \
    || bad "openai-oauth: cache_creation_input_tokens still mapped to cacheWrite (got $cw)"
else
  bad "openai session produces output ($outfile missing; stderr: $(cat "$tmp/err2"))"
fi

# 2b. Plain "openai" and "grok-build" provider keys get the same subtraction;
#     input floors at 0 rather than going negative.
s2b="$tmp/s2b/sessions"
mkdir -p "$s2b"
cat >"$s2b/session_oa2.json" <<'EOF'
{"id": "session_oa2", "model": "gpt-6-astra", "provider_key": "openai",
 "messages": [{"id": "oa2-1", "role": "assistant", "timestamp": "2026-09-10T12:00:01.000000Z",
   "token_usage": {"input_tokens": 500, "output_tokens": 10, "cache_read_input_tokens": 600}}]}
EOF
cat >"$s2b/session_grok.json" <<'EOF'
{"id": "session_grok", "model": "grok-4.6-build", "provider_key": "grok-build",
 "messages": [{"id": "grok-1", "role": "assistant", "timestamp": "2026-09-10T12:00:02.000000Z",
   "token_usage": {"input_tokens": 200, "output_tokens": 5, "cache_read_input_tokens": 50}}]}
EOF
out2b="$tmp/out2b"
run_convert "$s2b" "$out2b" >"$tmp/err2b" 2>&1
inp_oa2="$(line_field "$out2b/session_oa2.jsonl" 0 'd["message"]["usage"]["input"]')"
[ "$inp_oa2" = "0" ] && pass "openai (bare): input floors at 0 rather than going negative (500-600)" \
  || bad "openai (bare): input floors at 0 (got $inp_oa2)"
inp_grok="$(line_field "$out2b/session_grok.jsonl" 0 'd["message"]["usage"]["input"]')"
[ "$inp_grok" = "150" ] && pass "grok-build: same subtraction rule applies (200-50=150)" \
  || bad "grok-build: same subtraction rule applies (got $inp_grok)"

# ---------------------------------------------------------------------------
# 3. Journal file: dedupe by message id across .json + .journal.jsonl; journal
#    line's own meta.model/provider_key used when present; falls back to the
#    session-level model when a journal line's meta omits it.
# ---------------------------------------------------------------------------
s3="$tmp/s3/sessions"
mkdir -p "$s3"
cat >"$s3/session_frog.json" <<'EOF'
{
  "id": "session_frog",
  "model": "claude-opus-5",
  "provider_key": "claude-oauth",
  "messages": [
    {"id": "frog-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
      "token_usage": {"input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0}}
  ]
}
EOF
cat >"$s3/session_frog.journal.jsonl" <<'EOF'
{"meta":{"model":"gpt-5.6-sol","provider_key":"openai-oauth"},"append_messages":[{"id":"frog-2","role":"assistant","timestamp":"2026-09-10T12:00:01.000000Z","token_usage":{"input_tokens":500,"output_tokens":20,"cache_read_input_tokens":400}}]}
{"meta":{},"append_messages":[{"id":"frog-3","role":"assistant","timestamp":"2026-09-10T12:00:02.000000Z","token_usage":{"input_tokens":30,"output_tokens":2,"cache_read_input_tokens":0}}]}
{"meta":{"model":"gpt-5.6-sol","provider_key":"openai-oauth"},"append_messages":[{"id":"frog-1","role":"assistant","timestamp":"2026-09-10T12:00:00.000000Z","token_usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":0}}]}
EOF
out3="$tmp/out3"
run_convert "$s3" "$out3" >"$tmp/err3" 2>&1
outfile="$out3/session_frog.jsonl"
if [ -f "$outfile" ]; then
  n="$(n_lines "$outfile")"
  [ "$n" = "3" ] && pass "journal + json dedupe by message id (frog-1 counted once, 3 total not 4)" \
    || bad "journal + json dedupe by message id (got $n lines, want 3)"

  m2_model="$(python3 -c "
import json
for l in open('$outfile'):
    d = json.loads(l)
    # frog-2's usage: input=100 after cache subtraction (500-400)
    if d['message']['usage']['input'] == 100:
        print(d['message']['model']); break
")"
  [ "$m2_model" = "gpt-5.6-sol" ] && pass "journal line's own meta.model used for its message" \
    || bad "journal line's own meta.model used for its message (got $m2_model)"

  m3_model="$(python3 -c "
import json
for l in open('$outfile'):
    d = json.loads(l)
    if d['message']['usage']['input'] == 30:
        print(d['message']['model']); break
")"
  [ "$m3_model" = "claude-opus-5" ] && pass "journal line with empty meta falls back to session-level model" \
    || bad "journal line with empty meta falls back to session-level model (got $m3_model)"
else
  bad "session+journal dedupe test produces output ($outfile missing; stderr: $(cat "$tmp/err3"))"
fi

# ---------------------------------------------------------------------------
# 4. .bak handling: ignored when .json is present and valid; used when .json is
#    missing; used when .json is unparseable; a "pre-wipe"-style double-extension
#    .bak (real trap found on the mini) is never mistaken for a stem's own .bak.
# ---------------------------------------------------------------------------
s4="$tmp/s4/sessions"
mkdir -p "$s4"
# 4a. .json present and valid: .bak (stale/different content) must be ignored.
cat >"$s4/session_bakignore.json" <<'EOF'
{"id": "session_bakignore", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "bi-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
   "token_usage": {"input_tokens": 111, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
cat >"$s4/session_bakignore.bak" <<'EOF'
{"id": "session_bakignore", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "bi-STALE", "role": "assistant", "timestamp": "2026-09-09T12:00:00.000000Z",
   "token_usage": {"input_tokens": 999, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
# 4b. .json missing entirely: use .bak.
cat >"$s4/session_bakonly.bak" <<'EOF'
{"id": "session_bakonly", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "bo-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
   "token_usage": {"input_tokens": 222, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
# 4c. .json present but unparseable: fall back to .bak.
printf '{not valid json' >"$s4/session_bakfallback.json"
cat >"$s4/session_bakfallback.bak" <<'EOF'
{"id": "session_bakfallback", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "bf-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
   "token_usage": {"input_tokens": 333, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
# 4d. "pre-wipe"-style double-extension .bak files must never be read as a
#     primary session (this exact filename shape was found on the real mini).
cat >"$s4/session_prewipe.json" <<'EOF'
{"id": "session_prewipe", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "pw-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
   "token_usage": {"input_tokens": 444, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
cat >"$s4/session_prewipe.json.pre-wipe-1788559809587.bak" <<'EOF'
{"id": "session_prewipe", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "pw-GHOST", "role": "assistant", "timestamp": "2026-09-08T12:00:00.000000Z",
   "token_usage": {"input_tokens": 12345, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
# 4e. an unrelated tmp file (jcode's real crash-write naming) must be ignored.
cat >"$s4/session_prewipe.tmp.41569.9542241825316270497" <<'EOF'
not even json, and must never be read
EOF

out4="$tmp/out4"
run_convert "$s4" "$out4" >"$tmp/err4" 2>&1

ids_bakignore="$(python3 -c "
import json
print([json.loads(l)['message']['usage']['input'] for l in open('$out4/session_bakignore.jsonl')])
" 2>/dev/null)"
[ "$ids_bakignore" = "[111]" ] && pass ".bak ignored when .json is present and valid" \
  || bad ".bak ignored when .json is present and valid (got $ids_bakignore)"

if [ -f "$out4/session_bakonly.jsonl" ]; then
  inp="$(line_field "$out4/session_bakonly.jsonl" 0 'd["message"]["usage"]["input"]')"
  [ "$inp" = "222" ] && pass ".bak used when .json is missing entirely" \
    || bad ".bak used when .json is missing entirely (got $inp)"
else
  bad ".bak used when .json is missing entirely (no output file written)"
fi

if [ -f "$out4/session_bakfallback.jsonl" ]; then
  inp="$(line_field "$out4/session_bakfallback.jsonl" 0 'd["message"]["usage"]["input"]')"
  [ "$inp" = "333" ] && pass ".bak used when .json exists but is unparseable" \
    || bad ".bak used when .json exists but is unparseable (got $inp)"
else
  bad ".bak used when .json exists but is unparseable (no output file written)"
fi

if [ -f "$out4/session_prewipe.jsonl" ]; then
  ids_prewipe="$(python3 -c "
import json
print([json.loads(l)['message']['usage']['input'] for l in open('$out4/session_prewipe.jsonl')])
")"
  [ "$ids_prewipe" = "[444]" ] && pass "pre-wipe-style double-extension .bak never substitutes for the real session" \
    || bad "pre-wipe-style double-extension .bak never substitutes for the real session (got $ids_prewipe)"
else
  bad "pre-wipe fixture produces normal output (file missing)"
fi

# The pre-wipe .bak and the stray .tmp.* file must never become their own
# "session" output files.
stray_outputs="$(ls "$out4" 2>/dev/null | grep -c 'pre-wipe\|tmp\.41569' || true)"
[ "$stray_outputs" = "0" ] && pass "pre-wipe/.tmp files never produce their own output file" \
  || bad "pre-wipe/.tmp files never produce their own output file (found $stray_outputs)"

# ---------------------------------------------------------------------------
# 5. Corrupt/unreadable files: skipped, counted, one stderr summary line.
# ---------------------------------------------------------------------------
s5="$tmp/s5/sessions"
mkdir -p "$s5"
printf '{totally broken' >"$s5/session_corrupt1.json"
printf '{also broken' >"$s5/session_corrupt2.json"
cat >"$s5/session_ok.json" <<'EOF'
{"id": "session_ok", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "ok-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
   "token_usage": {"input_tokens": 55, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
out5="$tmp/out5"
run_convert "$s5" "$out5" >"$tmp/out5.log" 2>"$tmp/err5"
grep -qF "jcode-to-pi: skipped 2 unreadable jcode session file(s)" "$tmp/err5" \
  && pass "corrupt files: skipped, counted, one stderr summary line" \
  || bad "corrupt files: skipped, counted, one stderr summary line (stderr: $(cat "$tmp/err5"))"
[ -f "$out5/session_ok.jsonl" ] && pass "corrupt files do not abort the whole run (good session still converted)" \
  || bad "corrupt files do not abort the whole run (session_ok.jsonl missing)"

# ---------------------------------------------------------------------------
# 6. All-zero record is skipped entirely (no line written).
# ---------------------------------------------------------------------------
s6="$tmp/s6/sessions"
mkdir -p "$s6"
cat >"$s6/session_zero.json" <<'EOF'
{"id": "session_zero", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [
   {"id": "z-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
     "token_usage": {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}},
   {"id": "z-2", "role": "assistant", "timestamp": "2026-09-10T12:00:01.000000Z",
     "token_usage": {"input_tokens": 1, "output_tokens": 0, "cache_read_input_tokens": 0}}
 ]}
EOF
out6="$tmp/out6"
run_convert "$s6" "$out6" >"$tmp/err6" 2>&1
n="$(n_lines "$out6/session_zero.jsonl")"
[ "$n" = "1" ] && pass "all-zero-token record skipped, non-zero record kept" \
  || bad "all-zero-token record skipped (got $n lines, want 1)"

# ---------------------------------------------------------------------------
# 7. Missing sessions dir: write nothing, exit 0.
# ---------------------------------------------------------------------------
out7="$tmp/out7"
python3 "$script" --out "$out7" --sessions "$tmp/does-not-exist" >"$tmp/out7.log" 2>"$tmp/err7"
rc=$?
[ "$rc" = "0" ] && pass "missing sessions dir exits 0" || bad "missing sessions dir exits 0 (got $rc)"
[ ! -d "$out7" ] || [ -z "$(ls -A "$out7" 2>/dev/null)" ]
if [ $? -eq 0 ]; then pass "missing sessions dir writes nothing"; else bad "missing sessions dir writes nothing (out dir has files)"; fi

# 7b. A path that EXISTS but is a plain file, not a directory (not just
# absent), must be treated the same way -- exit 0, nothing written -- rather
# than crashing on NotADirectoryError.
s7b_file="$tmp/s7b-not-a-dir"
: >"$s7b_file"
out7b="$tmp/out7b"
python3 "$script" --out "$out7b" --sessions "$s7b_file" >"$tmp/out7b.log" 2>"$tmp/err7b"
rc=$?
[ "$rc" = "0" ] && pass "sessions path that is a file (not a dir) exits 0, not a crash" \
  || bad "sessions path that is a file (not a dir) exits 0 (got $rc, stderr: $(cat "$tmp/err7b"))"

# ---------------------------------------------------------------------------
# 8. Default sessions dir resolution: $JCODE_HOME/sessions when --sessions is
#    omitted.
# ---------------------------------------------------------------------------
s8home="$tmp/s8home"
mkdir -p "$s8home/sessions"
cat >"$s8home/sessions/session_home.json" <<'EOF'
{"id": "session_home", "model": "claude-sonnet-5", "provider_key": "claude-oauth",
 "messages": [{"id": "h-1", "role": "assistant", "timestamp": "2026-09-10T12:00:00.000000Z",
   "token_usage": {"input_tokens": 77, "output_tokens": 1, "cache_read_input_tokens": 0}}]}
EOF
out8="$tmp/out8"
JCODE_HOME="$s8home" python3 "$script" --out "$out8" >"$tmp/out8.log" 2>"$tmp/err8"
if [ -f "$out8/session_home.jsonl" ]; then
  pass "JCODE_HOME env var selects <JCODE_HOME>/sessions when --sessions is omitted"
else
  bad "JCODE_HOME env var selects <JCODE_HOME>/sessions (no output; stderr: $(cat "$tmp/err8"))"
fi

# ---------------------------------------------------------------------------
# 9. End-to-end timestamp check: the real ccusage binary must actually price
#    the converted output (proves truncation works against the real parser,
#    not just our own JSON reading of the intermediate file).
# ---------------------------------------------------------------------------
if [ -x "$ccusage_bin" ]; then
  e2e_json="$(cd "$tmp" && "$ccusage_bin" pi monthly --json --pi-path "$out1" --offline 2>"$tmp/e2e_err")"
  if [ -n "$e2e_json" ]; then
    total_tokens="$(get 'd["monthly"][0]["totalTokens"] if d.get("monthly") else 0' "$e2e_json")"
    [ "$total_tokens" != "0" ] && [ -n "$total_tokens" ] && pass "end-to-end: real ccusage counts tokens from the truncated timestamp (totalTokens=$total_tokens)" \
      || bad "end-to-end: real ccusage counts tokens from the truncated timestamp (got totalTokens=$total_tokens)"
  else
    bad "end-to-end ccusage run produced no JSON (stderr: $(cat "$tmp/e2e_err"))"
  fi
else
  bad "real ccusage binary not found at $ccusage_bin (build it: cd rust && cargo build --release -p ccusage-cli)"
fi

if (( failures > 0 )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all jcode-to-pi checks passed"
