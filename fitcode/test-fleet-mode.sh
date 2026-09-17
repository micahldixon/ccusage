#!/usr/bin/env bash
# Self-test for fleet-report.sh's jcode wiring and its --fleet option (no ccusage build, no
# ssh). A fake ccusage prints canned reports, adds a jcode row when its --config names the
# pi store "jcode", and logs how it was called; a fake ssh runs the remote command in zsh
# (the MacBook's shell) inside a local clone of a throwaway repo.
# FLEET_REPORT_SCRIPT=path tests another copy of the report (used to break it on purpose).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="${FLEET_REPORT_SCRIPT:-$here/fleet-report.sh}"
config_rs="$here/../rust/crates/ccusage-config/src/config.rs"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
failures=0

check() {  # check "description" command...
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}
has() { grep -qF -- "$2" "$1"; }                       # has FILE TEXT
lacks() { ! grep -qF -- "$2" "$1"; }
same() { cmp -s "$1" "$2"; }
json() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit(not eval(sys.argv[2]))' "$t/out" "$1"; }
one_err_line() {  # one_err_line TEXT...: stderr is one line holding every TEXT
  [[ "$(grep -c . "$t/err")" == 1 ]] || return 1
  local s
  for s; do has "$t/err" "$s" || return 1; done
}
err_is() { [[ "$(cat "$t/err")" == "$1" ]]; }   # err_is TEXT: stderr is exactly TEXT
runs() { [[ "$(grep -c '^call: ' "$t/fake/calls")" == "$1" ]]; }   # ccusage ran N times
called() { has "$t/fake/calls" "call: $1"; }            # called "arguments..." (a prefix)
called_exactly() { grep -qxF -- "call: $1" "$t/fake/calls"; }
store() { has "$t/fake/calls" "jcode store files: 1"; }   # jcode passed as a pi store
no_store() { lacks "$t/fake/calls" "jcode store"; }
exit_is() { [[ "$status" == "$1" ]]; }
failed() { (( status != 0 )); }
silent() { [[ ! -s "$t/out" ]]; }
no_err() { [[ ! -s "$t/err" ]]; }

mkdir -p "$t/fake" "$t/work" "$t/home" "$t/rbin" "$t/rhome/dev-tools" "$t/jcode-home/sessions" \
         "$t/repo/fitcode" "$t/repo/rust/crates/ccusage-config/src"

# Canned reports: local 2026-08 $1 + 2026-09 $2, remote 2026-07 $10 + 2026-09 $20; the fake adds
# jcode ($0.50, 50 tokens) to the last row.
python3 - "$t" <<'PY'
import json, sys
t = sys.argv[1]

def row(period, cost, tokens, model, agent, by_agent=False):
    base = {"modelsUsed": [model], "inputTokens": tokens, "outputTokens": 0,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": tokens,
            "totalCost": cost,
            "modelBreakdowns": [{"modelName": model, "inputTokens": tokens, "outputTokens": 0,
                                 "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": cost}]}
    r = dict(base, period=period, agent="all", metadata={"agents": [agent]})
    if by_agent:
        r["agents"] = [dict(base, agent=agent)]
    return r

def write(path, kind, rows):
    keys = ("inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens",
            "totalTokens", "totalCost")
    with open(f"{t}/{path}", "w") as f:
        json.dump({kind: rows, "totals": {k: sum(r[k] for r in rows) for k in keys}}, f)

opus = ("claude-opus-5", "claude")
for kind, period in (("daily", "2026-09-02"), ("weekly", "2026-08-31"), ("session", "s1"),
                     ("blocks", "b1")):
    write(f"fake/all-{kind}.json", kind, [row(period, 2.0, 200, *opus)])
    write(f"fake/all-{kind}-by-agent.json", kind, [row(period, 2.0, 200, *opus, by_agent=True)])
write("fake/all-monthly.json", "monthly", [row("2026-08", 1.0, 100, *opus),
                                           row("2026-09", 2.0, 200, *opus)])
write("fake/all-monthly-by-agent.json", "monthly",
      [row("2026-09", 2.0, 200, *opus, by_agent=True)])
write("rhome/remote-monthly.json", "monthly", [row("2026-07", 10.0, 1000, "gpt-6", "codex"),
                                               row("2026-09", 20.0, 2000, "gpt-6", "codex")])
write("rhome/remote-weekly.json", "weekly", [row("2026-08-31", 20.0, 2000, "gpt-6", "codex")])
PY

cat >"$t/fake/ccusage" <<'EOF'
#!/usr/bin/env bash
# Fake ccusage: logs each call (and the jcode store in any --config), prints a canned report.
echo "call: $*" >>"$FAKE_DIR/calls"
kind="" json=0 suffix="" prev="" jcode=""
for a in "$@"; do
  if [[ "$prev" == --config ]]; then
    jcode="$(python3 -c 'import json, sys
for s in json.load(open(sys.argv[1])).get("pi", {}).get("stores", []):
    if s["name"] == "jcode": print(s["path"])' "$a" 2>/dev/null)"
    [[ -z "$jcode" ]] ||
      echo "jcode store files: $(ls "$jcode" | wc -l | tr -d ' ') at $jcode" >>"$FAKE_DIR/calls"
  fi
  case "$a" in
    --json) json=1 ;;
    --by-agent) suffix=-by-agent ;;
    daily|weekly|monthly|session|blocks) kind="${kind:-$a}" ;;
  esac
  prev="$a"
done
kind="${kind:-daily}"
touch "$FAKE_DIR/local-started"
if [[ -n "${FAKE_SLEEP:-}" ]]; then  # let the test send a signal to the wrapper mid-run
  echo $$ >"$FAKE_DIR/local-pid"
  sleep "$FAKE_SLEEP"
fi
if [[ -n "${FAKE_PARALLEL:-}" ]]; then  # the other Mac's report must be running meanwhile
  for i in $(seq 25); do [[ -e "$FAKE_DIR/../rhome/remote-started" ]] && break; sleep 0.2; done
  [[ -e "$FAKE_DIR/../rhome/remote-started" ]] || { echo "other Mac never started" >&2; exit 1; }
fi
[[ -z "${FAKE_MAIN_FAIL:-}" ]] || { echo "ccusage failed" >&2; exit 1; }
if [[ -n "$jcode" ]]; then
  case "${FAKE_STORE:-}" in
    fail) echo "Error: Invalid ccusage config: pi.stores name 'jcode' collides" >&2; exit 2 ;;
    silent) exit 3 ;;
    sigpipe) exit 141 ;;
    epipe) echo "TABLE $kind"; echo 'Error: CliError("Broken pipe (os error 32)")' >&2; exit 1 ;;
    multiline) printf 'Error: something broke\ncaused by: root issue\nhint: try again\n' >&2; exit 4 ;;
  esac
fi
[[ -z "${FAKE_WARN:-}" ]] || echo "warning: something odd" >&2
if (( ! json )); then
  echo "TABLE $kind"
  [[ -z "$jcode" ]] || echo "- jcode"
  exit 0
fi
python3 - "$FAKE_DIR/all-$kind$suffix.json" "$jcode" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if sys.argv[2]:
    kind = next(k for k in d if k != "totals")
    row = d[kind][-1]
    j = {"modelsUsed": ["[jcode] gpt-6"], "inputTokens": 50, "outputTokens": 0,
         "cacheCreationTokens": 0, "cacheReadTokens": 0, "totalTokens": 50, "totalCost": 0.5,
         "modelBreakdowns": [{"modelName": "[jcode] gpt-6", "inputTokens": 50, "outputTokens": 0,
                              "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0.5}]}
    for k in ("inputTokens", "totalTokens", "totalCost"):
        row[k] += j[k]
        d["totals"][k] += j[k]
    row["modelsUsed"] += j["modelsUsed"]
    row["modelBreakdowns"] += j["modelBreakdowns"]
    row["metadata"]["agents"].append("jcode")
    if "agents" in row:
        row["agents"].append(dict(j, agent="jcode"))
json.dump(d, sys.stdout)
PY
EOF

cat >"$t/fake/ssh" <<'EOF'
#!/usr/bin/env bash
# Fake ssh: `ssh host command` runs command in zsh with HOME at the fake remote home.
echo "$1" >>"$FAKE_DIR/ssh-hosts"
echo "$$" >>"$FAKE_DIR/ssh-pids"
[[ -z "${FAKE_UNREACHABLE:-}" ]] || { echo "ssh: connect to host $1: Operation timed out" >&2; exit 255; }
cd "$FAKE_DIR/../rhome" && HOME="$FAKE_DIR/../rhome" PATH="$FAKE_DIR/../rbin:$PATH" exec zsh -c "$2"
EOF

# Stands in for the real ssh when FLEET_REMOTE_CMD is empty: records the options, then acts as above.
mkdir -p "$t/sshbin"
cat >"$t/sshbin/ssh" <<'EOF'
#!/usr/bin/env bash
opts=()
while [[ "$1" == -o ]]; do opts+=("$1" "$2"); shift 2; done
echo "${opts[*]}" >>"$FAKE_DIR/ssh-options"
exec "$FAKE_DIR/ssh" "$@"
EOF

printf '#!/bin/sh\necho "${FAKE_HOSTNAME:-macbook-fake}"\n' >"$t/rbin/hostname"

# The other Mac's checkout runs this stub in place of its own report.
cat >"$t/repo/fitcode/fleet-report.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HOME/remote-args"
touch "$HOME/remote-started"
if [[ -n "${FAKE_PARALLEL:-}" ]]; then  # this Mac's report must be running meanwhile
  for i in $(seq 25); do [[ -e "$FAKE_DIR/local-started" ]] && break; sleep 0.2; done
  [[ -e "$FAKE_DIR/local-started" ]] || { echo "this Mac never started" >&2; exit 1; }
fi
[[ -z "${FAKE_REMOTE_SLOW:-}" ]] || { sleep 4; touch "$HOME/remote-finished"; }
[[ -z "${FAKE_REMOTE_FAIL:-}" ]] || { echo "remote report broke" >&2; exit 3; }
kind=monthly
for a; do case "$a" in daily|weekly|monthly) kind="$a"; break ;; esac; done
cat "$HOME/remote-$kind.json"
EOF
chmod +x "$t/fake/ccusage" "$t/fake/ssh" "$t/sshbin/ssh" "$t/rbin/hostname" "$t/repo/fitcode/fleet-report.sh"
cp "$here/merge-reports.py" "$here/jcode-to-pi.py" "$here/dsh-to-pi.py" "$t/repo/fitcode/"
repo_config_rs="$t/repo/rust/crates/ccusage-config/src/config.rs"
cp "$config_rs" "$repo_config_rs"
echo "upstream code" >"$t/repo/rust/README"
echo "{}" >"$t/repo/flake.lock"
g() { git -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
        -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"; }
g -C "$t/repo" init -q && g -C "$t/repo" add -A && g -C "$t/repo" commit -qm fixture
g clone -q "$t/repo" "$t/rhome/dev-tools/ccusage"
clone="$t/rhome/dev-tools/ccusage"

cat >"$t/jcode-home/sessions/s1.json" <<'EOF'
{"model": "gpt-6", "provider_key": "openai-oauth", "messages": [{"id": "m1", "role": "assistant",
 "timestamp": "2026-09-02T10:00:00.123456Z", "token_usage": {"input_tokens": 10, "output_tokens": 5}}]}
EOF

run() {  # run [VAR=value...] -- [report arguments...]
  local -a vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
  shift
  : >"$t/fake/calls"
  rm -f "$t/fake/ssh-hosts" "$t/fake/ssh-pids" "$t/fake/ssh-options" "$t/fake/local-started" "$t/rhome/remote-args" \
        "$t/rhome/remote-started" "$t/rhome/remote-finished"
  (cd "$t/work" && env -u CLAUDE_CONFIG_DIR -u ANTIGRAVITY_DATA_DIR -u PI_AGENT_DIR \
     -u FLEET_REMOTE -u FLEET_REPORT_DRY \
     HOME="$t/home" FAKE_DIR="$t/fake" FLEET_REPORT_BIN="$t/fake/ccusage" \
     FLEET_REPORT_REPO="$t/repo" FLEET_REMOTE_CMD="$t/fake/ssh" \
     JCODE_HOME="$t/jcode-home" TZ=Pacific/Auckland ${vars[@]+"${vars[@]}"} \
     bash "$script" "$@") >"$t/out" 2>"$t/err"
  status=$?
}
jcode_added() {  # jcode_added FIXTURE: the output is FIXTURE plus the fake's jcode row
  python3 - "$t/out" "$t/fake/$1" <<'PY'
import json, sys
out, base = (json.load(open(p)) for p in sys.argv[1:])
kind = next(k for k in base if k != "totals")
row = out[kind][-1]
sys.exit(not (out["totals"]["totalTokens"] == base["totals"]["totalTokens"] + 50
              and "jcode" in row["metadata"]["agents"] and "[jcode] gpt-6" in row["modelsUsed"]))
PY
}

echo "# jcode: every all-agents report"
run JCODE_HOME="$t/no-jcode" -- monthly --json
check "no jcode: report printed unchanged" same "$t/out" "$t/fake/all-monthly.json"
check "no jcode: no store config" no_store
check "no jcode: no warning" no_err

for kind in daily weekly monthly session; do
  run -- "$kind" --json
  check "$kind json: exit 0" exit_is 0
  check "$kind json: jcode passed as a pi store" store
  check "$kind json: jcode added to the report" jcode_added "all-$kind.json"
  check "$kind json: ccusage ran once" runs 1
  check "$kind json: no warning" no_err
  run -- "$kind"
  check "$kind table: jcode row shown" has "$t/out" "- jcode"
  check "$kind table: arguments kept, store config added" \
    grep -qE "^call: $kind --config .*/fleet-report-ag\.[^/]+/config\.json$" "$t/fake/calls"
done
check "store path is the converted folder in the temp folder" \
  grep -qE 'jcode store files: 1 at .*/fleet-report-ag\.[^/]+/jcode$' "$t/fake/calls"

for kind in monthly weekly; do
  run -- "$kind" --json --by-agent
  check "$kind --by-agent: nested jcode entry" \
    json '[a["agent"] for a in d["'"$kind"'"][-1]["agents"]] == ["claude", "jcode"]'
  check "$kind --by-agent: jcode in metadata.agents" \
    json '"jcode" in d["'"$kind"'"][-1]["metadata"]["agents"]'
done

run -- --json
check "default command: jcode added to the daily report" jcode_added all-daily.json

run -- monthly --sections daily,monthly --json
check "--sections: jcode passed as a pi store" store

run -- monthly --json -s=20260901 --until 20260930 -z=UTC --offline --order desc
check "filters: passed unchanged, store config last" \
  called "monthly --json -s=20260901 --until 20260930 -z=UTC --offline --order desc --config "
check "filters: jcode passed as a pi store" store

run -- -s=20260901 weekly --json
check "kind after -s=VALUE: weekly found" store
run -- -s=20260901 claude daily --json
check "kind after -s=VALUE: claude found, jcode left out" no_store
run -- --since 20260901 -o=desc session
check "kind after --since VALUE: session found" store
run -- -z UTC claude daily --json
check "kind after -z VALUE: claude found, jcode left out" no_store

# Every option ccusage reads a value for (config.rs option_takes_value) keeps that value out
# of the report kind; a new upstream option fails here until fleet-report.sh lists it.
value_options="$(python3 - "$config_rs" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
body = src[src.index("fn option_takes_value"):src.index("fn is_agent_command")]
print(" ".join(o for o in re.findall(r'"(-[^"]*)"', body) if o != "--config"))
PY
)"
kind_after_every_value() {
  local opt
  [[ "$(wc -w <<<"$value_options")" -ge 25 ]] || { echo "     (found only: $value_options)"; return 1; }
  for opt in $value_options; do
    run -- "$opt" x monthly --json
    store || { echo "     ($opt x: the kind was lost)"; return 1; }
  done
}
check "kind found after each value-taking option in config.rs" kind_after_every_value

run FAKE_WARN=1 -- monthly
check "ccusage warnings: passed through" one_err_line "warning: something odd"
check "ccusage warnings: exit 0" exit_is 0

echo "# jcode: reports that leave it out"
for words in "blocks" "blocks --json" "claude daily --json" "pi monthly --json" "codex session"; do
  read -r -a argv <<<"$words"
  run -- "${argv[@]}"
  check "$words: no store config" no_store
  check "$words: ccusage ran once, with the user's arguments only" called_exactly "$words"
  check "$words: one stderr line says why" one_err_line "jcode not included" "not '${argv[0]}'"
done
run -- blocks --json
check "blocks: report unchanged" same "$t/out" "$t/fake/all-blocks.json"

echo '{}' >"$t/work/mine.json"
for form in "--config $t/work/mine.json" "--config=$t/work/mine.json"; do
  read -r -a argv <<<"monthly --json $form"
  run -- "${argv[@]}"
  check "$form: no store config" no_store
  check "$form: only the user's config" called_exactly "monthly --json $form"
  check "$form: one stderr line says why" one_err_line "jcode not included" "--config"
  check "$form: report unchanged" same "$t/out" "$t/fake/all-monthly.json"
done

# Files ccusage would read settings from (config.rs discover_config_paths).
mkdir -p "$t/work/.ccusage"
echo '{}' >"$t/work/.ccusage/ccusage.json"
run -- monthly --json
check "config in ./.ccusage: no store config" no_store
check "config in ./.ccusage: one stderr line names it" \
  one_err_line "jcode not included" "$t/work/.ccusage/ccusage.json"
rm -r "$t/work/.ccusage"

mkdir -p "$t/home/.config/claude"
echo '{}' >"$t/home/.config/claude/ccusage.json"
run -- monthly --json
check "config in ~/.config/claude (no Claude folders): left out" \
  one_err_line "jcode not included" "$t/home/.config/claude/ccusage.json"
run CLAUDE_CONFIG_DIR= -- monthly --json
check "empty CLAUDE_CONFIG_DIR: home folders not searched" store
mkdir -p "$t/home/.claude/projects"
run -- monthly --json
check "config outside the Claude folders passed to ccusage: jcode kept" store
echo '{}' >"$t/home/.claude/ccusage.json"
run -- monthly --json
check "config in a passed Claude folder: left out" \
  one_err_line "jcode not included" "$t/home/.claude/ccusage.json"
rm -r "$t/home/.claude" "$t/home/.config"

mkdir -p "$t/cfg dir"
echo '{}' >"$t/cfg dir/ccusage.json"
run CLAUDE_CONFIG_DIR="/nowhere, $t/cfg dir ," -- monthly --json
check "CLAUDE_CONFIG_DIR entries are trimmed like ccusage does" \
  one_err_line "jcode not included" "$t/cfg dir/ccusage.json"
run CLAUDE_CONFIG_DIR="/nowhere" -- monthly --json
check "CLAUDE_CONFIG_DIR replaces the search" store

# The guard on ccusage's config search: a changed or unreadable config.rs leaves jcode out.
check "config.rs unchanged: guard passes" store
sed 's/"\.claude"/".claude-x"/' "$config_rs" >"$repo_config_rs"
run -- monthly --json
check "config search changed: no store config" no_store
check "config search changed: one stderr line tells the maintainer" \
  one_err_line "jcode not included" "config_search_hash"
: >"$repo_config_rs"
run -- monthly --json
check "config search unreadable: no store config" no_store
check "config search unreadable: one stderr line" one_err_line "jcode not included" "config_search_hash"
sed 's/fs::read_to_string(path)\.ok()/fs::read_to_string(path).ok() \/\/ guard-test/' "$config_rs" >"$repo_config_rs"
run -- monthly --json
check "load_config_value edited: no store config" no_store
check "load_config_value edited: one stderr line tells the maintainer" \
  one_err_line "jcode not included" "config_search_hash"
cp "$config_rs" "$repo_config_rs"

printf 'import sys\nsys.exit("jcode-to-pi: disk on fire")\n' >"$t/repo/fitcode/jcode-to-pi.py"
run -- monthly --json
check "converter fails: report unchanged" same "$t/out" "$t/fake/all-monthly.json"
check "converter fails: one stderr line with its reason" \
  one_err_line "jcode not included" "converted: jcode-to-pi: disk on fire"
printf 'raise SystemExit(1)\n' >"$t/repo/fitcode/jcode-to-pi.py"
run -- monthly --json
check "converter fails silently: still a reason" \
  one_err_line "jcode not included" "jcode-to-pi.py printed no error message"
g -C "$t/repo" checkout -q -- fitcode/jcode-to-pi.py

mkdir -p "$t/jcode-warn/sessions"
cp "$t/jcode-home/sessions/s1.json" "$t/jcode-warn/sessions/"
echo 'not json' >"$t/jcode-warn/sessions/bad.json"
run JCODE_HOME="$t/jcode-warn" -- monthly --json
check "converter warning: passed through" one_err_line "skipped 1 unreadable jcode session"
check "converter warning: jcode still added" store

echo "# jcode: the report with jcode fails"
run FAKE_STORE=fail -- monthly --json
check "fails: ccusage's exit status" exit_is 2
check "fails: ccusage's own message passed through, then the reason" \
  err_is "$(printf "Error: Invalid ccusage config: pi.stores name 'jcode' collides\nfleet-report: ccusage failed (exit 2; jcode was added as a pi store)")"
check "fails: report not run again" runs 1
run FAKE_STORE=multiline -- monthly --json
check "fails with a multi-line error: ccusage's exit status" exit_is 4
check "fails with a multi-line error: ccusage's full message reaches the user, then the reason" \
  err_is "$(printf 'Error: something broke\ncaused by: root issue\nhint: try again\nfleet-report: ccusage failed (exit 4; jcode was added as a pi store)')"
check "fails with a multi-line error: report not run again" runs 1
run FAKE_STORE=silent -- monthly
check "fails silently: ccusage's exit status" exit_is 3
check "fails silently (empty ccusage stderr): says so, then the reason" \
  err_is "$(printf 'fleet-report: ccusage printed no error message\nfleet-report: ccusage failed (exit 3; jcode was added as a pi store)')"
check "fails silently: report not run again" runs 1
run FAKE_STORE=sigpipe -- monthly
check "reader stopped (SIGPIPE): exit 0" exit_is 0
check "reader stopped (SIGPIPE): no message" no_err
check "reader stopped (SIGPIPE): report not run again" runs 1
run FAKE_STORE=epipe -- monthly
check "reader stopped (Broken pipe): exit 0" exit_is 0
check "reader stopped (Broken pipe): no message" no_err
check "reader stopped (Broken pipe): report not run again" runs 1
run FAKE_MAIN_FAIL=1 JCODE_HOME="$t/no-jcode" -- monthly --json
check "plain report fails: exit non-zero" failed

echo "# --fleet"
local_host="$(hostname -s)"
remote_args() { printf '%s\n' "$@" | cmp -s - "$t/rhome/remote-args"; }
run JCODE_HOME="$t/no-jcode" -- monthly --json --fleet --since 20260701
check "fleet json: exit 0" exit_is 0
check "fleet json: totals are the sum of both Macs" \
  json 'd["totals"]["totalTokens"] == 3300 and round(d["totals"]["totalCost"], 6) == 33.0'
check "fleet json: periods from both Macs" \
  json '[r["period"] for r in d["monthly"]] == ["2026-07", "2026-08", "2026-09"]'
check "fleet: other Mac gets the same arguments and this Mac's zone" \
  remote_args monthly --json --since 20260701 --timezone Pacific/Auckland
check "fleet: this Mac uses the same zone" \
  called_exactly "monthly --json --since 20260701 --timezone Pacific/Auckland"
check "fleet: default host is macbook" has "$t/fake/ssh-hosts" "macbook"

run -- monthly --json --fleet
check "fleet with jcode: this Mac's jcode is in the total" \
  json 'd["totals"]["totalTokens"] == 3350 and "jcode" in d["monthly"][-1]["metadata"]["agents"]'
run -- --fleet weekly --json --by-agent
check "fleet weekly with jcode: nested jcode entry" \
  json '"jcode" in [a["agent"] for a in d["weekly"][-1]["agents"]]'
check "fleet weekly with jcode: totals add up" json 'd["totals"]["totalTokens"] == 2250'

run FLEET_REMOTE_CMD= PATH="$t/sshbin:$PATH" JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "fleet over ssh: exit 0" exit_is 0
check "fleet over ssh: never prompts, gives up on a sleeping Mac" has "$t/fake/ssh-options" \
  "-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

run FAKE_PARALLEL=1 JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "fleet: both reports run at once" exit_is 0

for zone in "-z UTC" "-z=UTC" "--timezone UTC" "--timezone=UTC"; do
  read -r -a argv <<<"$zone"
  run JCODE_HOME="$t/no-jcode" FLEET_REMOTE=studio -- --fleet monthly --json "${argv[@]}"
  check "fleet $zone: user's zone kept on the other Mac" remote_args monthly --json "${argv[@]}"
  check "fleet $zone: user's zone kept on this Mac" called_exactly "monthly --json $zone"
done
check "fleet: FLEET_REMOTE picks the host" has "$t/fake/ssh-hosts" "studio"

run JCODE_HOME="$t/no-jcode" -- -s=20260701 monthly --fleet --json
check "fleet: kind found after -s=VALUE" exit_is 0
check "fleet: -s=VALUE passed unchanged" \
  remote_args -s=20260701 monthly --json --timezone Pacific/Auckland

run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json --jq 'a b; touch pwned'
check "fleet: argument with spaces and ; arrives intact" \
  remote_args monthly --json --jq 'a b; touch pwned' --timezone Pacific/Auckland
check "fleet: argument is not run as a command" [ ! -e "$clone/pwned" ]
run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json --jq '~' --since '=ls'
check "fleet: leading ~ and = arrive intact" \
  remote_args monthly --json --jq '~' --since '=ls' --timezone Pacific/Auckland

run JCODE_HOME="$t/no-jcode" -- monthly --fleet
check "fleet table: exit 0" exit_is 0
check "fleet table: machine names in the header" \
  grep -qE "^period +$local_host +macbook-fake +fleet$" "$t/out"
check "fleet table: period only on the other Mac" \
  grep -qE '^2026-07 +- +\$10\.00 +1,000 tokens +\$10\.00 +1,000 tokens$' "$t/out"
check "fleet table: period only on this Mac" \
  grep -qE '^2026-08 +\$1\.00 +100 tokens +- +\$1\.00 +100 tokens$' "$t/out"
check "fleet table: shared period adds up" \
  grep -qE '^2026-09 +\$2\.00 +200 tokens +\$20\.00 +2,000 tokens +\$22\.00 +2,200 tokens$' "$t/out"
check "fleet table: totals line adds up" \
  grep -qE '^total +\$3\.00 +300 tokens +\$30\.00 +3,000 tokens +\$33\.00 +3,300 tokens$' "$t/out"
check "fleet table: other Mac still asked for JSON" remote_args monthly --json --timezone Pacific/Auckland

for words in "session" "blocks" "claude daily" "pi monthly"; do
  read -r -a argv <<<"$words"
  run -- "${argv[@]}" --fleet
  check "fleet $words: refused" failed
  check "fleet $words: says so" one_err_line "--fleet" "not '${argv[0]}'"
  check "fleet $words: other Mac never contacted" [ ! -e "$t/fake/ssh-hosts" ]
done

run -- -z=UTC session --fleet
check "fleet session after -z=VALUE: refused" failed

run JCODE_HOME="$t/no-jcode" -- monthly --fleet --sections daily,monthly
check "fleet --sections: refused" failed

run JCODE_HOME="$t/no-jcode" FAKE_UNREACHABLE=1 -- monthly --fleet
check "unreachable: exit non-zero" failed
check "unreachable: says which Mac" has "$t/err" "cannot reach macbook"
check "unreachable: prints no numbers" silent

run JCODE_HOME="$t/no-jcode" FAKE_HOSTNAME="$local_host" -- monthly --fleet --json
check "other Mac is this Mac: refused" failed
check "other Mac is this Mac: says so" has "$t/err" "is this Mac ($local_host)"
check "other Mac is this Mac: no report ran" [ ! -e "$t/rhome/remote-args" ]
check "other Mac is this Mac: prints no numbers" silent

run JCODE_HOME="$t/no-jcode" FAKE_REMOTE_FAIL=1 -- monthly --fleet
check "other Mac's report fails: exit non-zero" failed
check "other Mac's report fails: says so" has "$t/err" "macbook's report failed"
check "other Mac's report fails: prints no numbers" silent

SECONDS=0
run JCODE_HOME="$t/no-jcode" FAKE_MAIN_FAIL=1 FAKE_REMOTE_SLOW=1 -- monthly --fleet
elapsed=$SECONDS
check "this Mac's report fails: exit non-zero" failed
check "this Mac's report fails: says so" has "$t/err" "this Mac's report failed"
check "this Mac's report fails: prints no numbers" silent
check "this Mac's report fails: does not wait for the other Mac" [ "$elapsed" -lt 3 ]
ssh_pid="$(tail -1 "$t/fake/ssh-pids")"
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$ssh_pid" 2>/dev/null || break; sleep 0.2; done
check "this Mac's report fails: the other Mac's ssh is stopped" eval '! kill -0 "$ssh_pid" 2>/dev/null'

echo "# --fleet: TERM to the wrapper leaves no report running"
: >"$t/fake/calls"
rm -f "$t/fake/local-pid" "$t/fake/ssh-hosts" "$t/fake/ssh-pids" "$t/rhome/remote-started" "$t/rhome/remote-args"
oldpwd="$PWD"
cd "$t/work"
env -u CLAUDE_CONFIG_DIR -u ANTIGRAVITY_DATA_DIR -u PI_AGENT_DIR \
   -u FLEET_REMOTE -u FLEET_REPORT_DRY \
   HOME="$t/home" FAKE_DIR="$t/fake" FLEET_REPORT_BIN="$t/fake/ccusage" \
   FLEET_REPORT_REPO="$t/repo" FLEET_REMOTE_CMD="$t/fake/ssh" \
   JCODE_HOME="$t/no-jcode" TZ=Pacific/Auckland FAKE_SLEEP=6 FAKE_REMOTE_SLOW=1 \
   bash "$script" monthly --fleet --json >"$t/out" 2>"$t/err" &
wrapper_pid=$!
cd "$oldpwd"
for i in $(seq 25); do [[ -s "$t/fake/local-pid" && -s "$t/fake/ssh-pids" ]] && break; sleep 0.2; done
check "fleet TERM: this Mac's ccusage started" [ -s "$t/fake/local-pid" ]
local_pid="$(cat "$t/fake/local-pid" 2>/dev/null)"
term_ssh_pid="$(tail -1 "$t/fake/ssh-pids" 2>/dev/null)"
kill -TERM "$wrapper_pid" 2>/dev/null
wait "$wrapper_pid" 2>/dev/null
status=$?
check "fleet TERM: wrapper exits 143" exit_is 143
# A short poll: the fix kills these within well under a second. FAKE_SLEEP/FAKE_REMOTE_SLOW
# (6s/4s) are chosen so a left-running process (the bug) is still alive when this gives up.
for i in 1 2 3 4 5; do kill -0 "$local_pid" 2>/dev/null || break; sleep 0.2; done
check "fleet TERM: this Mac's ccusage no longer running" eval '! kill -0 "$local_pid" 2>/dev/null'
for i in 1 2 3 4 5; do kill -0 "$term_ssh_pid" 2>/dev/null || break; sleep 0.2; done
check "fleet TERM: the other Mac's ssh is also stopped" eval '! kill -0 "$term_ssh_pid" 2>/dev/null'

run JCODE_HOME="$t/no-jcode" TZ=/not/a/zone -- monthly --fleet
check "unknown zone: refused" failed
check "unknown zone: asks for --timezone" has "$t/err" "--timezone"

g -C "$clone" commit -q --allow-empty -m "newer"
run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "commit mismatch: exit non-zero" failed
check "commit mismatch: tells the user to pull" has "$t/err" "pull"
check "commit mismatch: prints no numbers" silent
check "commit mismatch: other Mac's report never ran" [ ! -e "$t/rhome/remote-args" ]
g -C "$clone" reset -q --hard HEAD~1

echo "edit" >>"$clone/rust/README"
run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "other Mac uncommitted: refused" failed
check "other Mac uncommitted: names the file" has "$t/err" "rust/README"
check "other Mac uncommitted: prints no numbers" silent
g -C "$clone" checkout -q -- rust/README

echo '{"edited": 1}' >"$clone/flake.lock"
run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "other Mac's flake.lock uncommitted: refused" failed
check "other Mac's flake.lock uncommitted: names it" has "$t/err" "flake.lock"
g -C "$clone" checkout -q -- flake.lock

echo '{"edited": 1}' >"$t/repo/flake.lock"
run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "this Mac's flake.lock uncommitted: refused" failed
check "this Mac's flake.lock uncommitted: names it" has "$t/err" "flake.lock"
g -C "$t/repo" checkout -q -- flake.lock

touch "$t/repo/fitcode/stray.py"
run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "this Mac uncommitted: refused" failed
check "this Mac uncommitted: names the file" has "$t/err" "fitcode/stray.py"
check "this Mac uncommitted: prints no numbers" silent
check "this Mac uncommitted: other Mac's report never ran" [ ! -e "$t/rhome/remote-args" ]
rm "$t/repo/fitcode/stray.py"

touch "$t/repo/fitcode/notes.md" "$clone/fitcode/plan.md"
run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "uncommitted notes on either Mac: fleet total still works" exit_is 0
rm "$t/repo/fitcode/notes.md" "$clone/fitcode/plan.md"

run JCODE_HOME="$t/no-jcode" -- monthly --fleet --json
check "clean again: fleet total works" exit_is 0

if (( failures > 0 )); then echo "$failures check(s) failed"; exit 1; fi
echo "all fleet-mode checks passed"
