#!/usr/bin/env bash
# Fleet usage report: runs this fork's ccusage over every coding agent it supports,
# with fixes the stock command lacks on our machines:
#
#   1. Claude: counts every account (claude, claude2/3/4 via ~/.claude-shared) and every
#      Claude.app Cowork session, not just ~/.claude. CLAUDE_CONFIG_DIR is set for ccusage only — Claude Code reads the same
#      variable, so never export it globally. Directories whose projects/ resolve to the
#      same place (the MacBook symlinks ~/.claude/projects into the shared pool) are
#      counted once.
#   2. Antigravity: upstream aborts the whole report on a conversation database without a
#      gen_metadata table (Antigravity leaves empty ones behind). Folders without such a
#      file are read in place. For a folder with one, we read APFS clones (`cp -c`: instant,
#      no extra disk) of its usable databases and their -wal files from a temp folder, and
#      say how many we skipped. Symlinks do not work: upstream's file walk ignores them.
#   3. jcode: ccusage has no jcode reader, so fitcode/jcode-to-pi.py rewrites its sessions in
#      pi's log format into the temp folder, and a temporary --config names that folder as
#      the pi store "jcode". ccusage reads such stores in its all-agents daily, weekly,
#      monthly and session reports, as a table or --json. Any other report, a --config
#      of the user's, a config file ccusage would find by itself (our --config would hide
#      it), or a conversion failure prints the plain report and says why on stderr.
#   4. --fleet (anywhere in the arguments) adds the other Mac's report, run over ssh at the
#      same time as this Mac's. It refuses when that Mac is unreachable, is this Mac, is on
#      another commit, or when either checkout has uncommitted changes to fitcode/ scripts,
#      rust/ or flake.lock, and gives both Macs this Mac's time zone unless --timezone is
#      passed. If this Mac gives up early (its own report fails, or TERM/INT is sent to this
#      script), its ssh to the other Mac stops right away, but the other Mac's report keeps
#      running on its own to completion; its output is simply discarded.
#
# Usage: fitcode/fleet-report.sh [--fleet] [ccusage arguments]   e.g. monthly --since 20260901
# Builds rust/target/release/ccusage with cargo on first use (no Nix needed).
# FLEET_REMOTE names the other Mac (default macbook). Used by the tests:
# FLEET_REPORT_DRY=1 prints the computed settings instead of running; FLEET_REPORT_BIN
# replaces ccusage and skips the build; FLEET_REPORT_REPO replaces the repo root;
# FLEET_REMOTE_CMD replaces ssh (called as `cmd host command`); jcode-to-pi.py reads JCODE_HOME.
set -euo pipefail

repo="${FLEET_REPORT_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
home="${HOME:?}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-report-ag.XXXXXX")"
mine="" remote=""  # the two --fleet reports while they run
stop() {  # stop PID...: each process and the processes it started
  local p kids
  for p; do
    kids="$(pgrep -P "$p" | tr '\n' ' ')" || true
    kill "$p" $kids 2>/dev/null || true
    wait "$p" 2>/dev/null || true
  done
}
trap 'stop $mine $remote; rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ccusage's config file search (discover_config_paths, claude_config_dirs, load_config_value,
# scan_config_path and command_uses_named_pi_stores), mirrored by config_files below. If
# upstream changes any of them, jcode is left out until someone re-checks config_files and
# updates this hash (sha256 of the sed extract in search_hash).
config_rs="$repo/rust/crates/ccusage-config/src/config.rs"
config_search_hash=57c4ac6c57a8ddae0b2d16f0cf9f79f68e81d3362f17692d63f1dbfde3d4a5bb

die() { echo "fleet-report: $*" >&2; exit 1; }

realdir() { (cd "$1" 2>/dev/null && pwd -P); }

claude_dirs() {
  local seen="" out="" d p
  # Claude.app Cowork keeps a normal Claude transcript folder per session; the app's Code tab
  # already writes to ~/.claude/projects.
  local cowork="$home/Library/Application Support/Claude/local-agent-mode-sessions"
  for d in "$home/.claude" "$home/.config/claude" "$home/.claude-shared" "$home"/.claude-account* \
           "$cowork"/*/*/local_*/.claude; do
    [[ -d "$d/projects" ]] || continue
    p="$(realdir "$d/projects")" || continue
    case "|$seen|" in *"|$p|"*) continue ;; esac
    seen="$seen|$p"
    out="${out:+$out,}$d"
  done
  printf '%s' "$out"
}

has_gen_metadata() {
  # Read-only first so tables still in the -wal count. A WAL database with no -shm cannot
  # be opened read-only; fall back to immutable mode for those.
  local q="select count(*) from sqlite_master where type='table' and name='gen_metadata'" n
  n="$(sqlite3 -readonly "$1" "$q" 2>/dev/null)" ||
    n="$(sqlite3 "file:$1?immutable=1" "$q" 2>/dev/null)" || n=0
  [[ "$n" == "1" ]]
}

# One pass over the arguments. The report kind is the first word that is neither an option
# nor an option's value (value-taking options as in rust/crates/ccusage-config/src/config.rs).
# Like ccusage, an option may carry its value after the first "=" (-s=20260901, -z=UTC).
fleet=0 json=0 sections=0 zone_given=0 config_given=0 kind=""
args=()
while (( $# > 0 )); do
  a="$1"
  shift
  [[ "$a" != --fleet ]] || { fleet=1; continue; }
  args+=("$a")
  name="$a"
  [[ "$a" != -*=* ]] || name="${a%%=*}"
  case "$name" in
    -j|--json) json=1 ;;
    --sections) sections=1 ;;
    -z|--timezone) zone_given=1 ;;
    --config) config_given=1 ;;
    -*) ;;
    *) kind="${kind:-$a}" ;;
  esac
  [[ "$name" == "$a" ]] || continue
  case "$name" in
    -s|--since|-u|--until|--last|-m|--mode|-o|--order|-z|--timezone|--config|-q|--jq| \
    --debug-samples|--sections|-t|--token-limit|-n|--session-length|-w|--start-of-week| \
    -p|--project|--project-aliases|--pi-path|--speed|-B|--visual-burn-rate|--cost-source| \
    --refresh-interval|--context-low-threshold|--context-medium-threshold)
      if (( $# > 0 )); then args+=("$1"); shift; fi ;;
  esac
done
kind="${kind:-daily}"

line() { sed -n "$1p" <<<"$2"; }

clean_checkout() {  # clean_checkout NAME STATE: STATE lines 3+ are uncommitted changes
  local changes
  changes="$(sed 1,2d <<<"$2")"
  [[ -z "$changes" ]] || die "$1 has uncommitted changes; commit them and pull both Macs first:"$'\n'"$changes"
}

if (( fleet )); then
  case "$kind" in
    daily|weekly|monthly) ;;
    *) die "--fleet adds up only the all-agents daily, weekly and monthly reports, not '$kind'" ;;
  esac
  (( ! sections )) || die "--fleet cannot add up --sections reports"
  (( json )) || args+=(--json)
  if (( ! zone_given )); then
    # ccusage groups dates in this Mac's zone ($TZ, else /etc/localtime); both Macs get it.
    zone="${TZ:-$(readlink /etc/localtime || true)}"
    zone="${zone#*/zoneinfo/}"
    [[ -n "$zone" && "$zone" != /* ]] || die "cannot tell this Mac's time zone; pass --timezone"
    args+=(--timezone "$zone")
  fi
  host="${FLEET_REMOTE:-macbook}"
  ssh=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
  [[ -z "${FLEET_REMOTE_CMD:-}" ]] || ssh=("$FLEET_REMOTE_CMD")
  # Commit, machine name, then any uncommitted change to the code the report runs (notes and
  # plans do not change the numbers; flake.lock pins the price list).
  state='git rev-parse HEAD && hostname -s &&
    git --no-optional-locks status --porcelain -- "fitcode/*.sh" "fitcode/*.py" rust flake.lock'
  here="$(cd "$repo" && eval "$state")" || die "cannot read this Mac's checkout"
  there="$("${ssh[@]}" "$host" "cd ~/dev-tools/ccusage && $state")" ||
    die "cannot reach $host or its ~/dev-tools/ccusage checkout (asleep?); no fleet total"
  [[ "$(line 2 "$here")" != "$(line 2 "$there")" ]] ||
    die "$host is this Mac ($(line 2 "$here")); set FLEET_REMOTE to the other Mac"
  [[ "$(line 1 "$here")" == "$(line 1 "$there")" ]] ||
    die "this Mac is on commit ${here:0:8} and $host on ${there:0:8}; pull both to the same commit"
  clean_checkout "this Mac" "$here"
  clean_checkout "$host" "$there"

  quoted=""
  for a in "${args[@]}"; do
    q="$(printf %q "$a")"
    [[ "$q" != [~=]* ]] || q="\\$q"  # bash 3.2's %q leaves a leading ~ or = bare; zsh expands both
    quoted+=" $q"
  done
  # Both reports run at once.
  "${ssh[@]}" "$host" "cd ~/dev-tools/ccusage && fitcode/fleet-report.sh$quoted" \
    </dev/null >"$tmp/there.json" &
  remote=$!
  bash "$0" "${args[@]}" </dev/null >"$tmp/here.json" &
  mine=$!
  wait "$mine" || die "this Mac's report failed; no fleet total"
  mine=""
  status=0
  wait "$remote" || status=$?
  remote=""
  (( status == 0 )) || die "$host's report failed; no fleet total"
  python3 "$repo/fitcode/merge-reports.py" "$tmp/here.json" "$tmp/there.json" >"$tmp/fleet.json" ||
    die "could not add the two reports together"
  if (( json )); then
    cat "$tmp/fleet.json"
    exit 0
  fi
  python3 - "$(line 2 "$here")" "$tmp/here.json" "$(line 2 "$there")" "$tmp/there.json" \
    fleet "$tmp/fleet.json" <<'PY'
import json, sys
names = sys.argv[1::2]
reports = [json.load(open(path)) for path in sys.argv[2::2]]
kind = next(k for k in ("daily", "weekly", "monthly") if k in reports[0])
rows = [{row["period"]: row for row in report[kind]} for report in reports]

def cell(row):
    return f"${row['totalCost']:,.2f}  {row['totalTokens']:,} tokens" if row else "-"

def show(label, cells):
    print(f"{label:<12}" + "".join(f"{c:>38}" for c in cells))

show("period", names)
for period in rows[-1]:
    show(period, [cell(r.get(period)) for r in rows])
show("total", [cell(report["totals"]) for report in reports])
PY
  exit 0
fi

claude="${CLAUDE_CONFIG_DIR:-$(claude_dirs)}"

ag="${ANTIGRAVITY_DATA_DIR:-}"
included=()
if [[ -z "$ag" ]]; then
  skipped=0 n=0 seen=""
  for root in .gemini/antigravity .gemini/antigravity-cli .gemini/antigravity-ide \
              .gemini/antigravity-backup .config/antigravity; do
    dir="$home/$root"
    [[ -d "$dir/conversations" ]] && dir="$dir/conversations"
    [[ -d "$dir" ]] || continue
    real="$(realdir "$dir")"
    case "|$seen|" in *"|$real|"*) continue ;; esac
    seen="$seen|$real"
    good=() bad=0
    while IFS= read -r -d '' f; do
      if has_gen_metadata "$f"; then good+=("$f"); else bad=$((bad + 1)); fi
    done < <(find "$dir" -type f -name '*.db' -print0 2>/dev/null)
    (( ${#good[@]} > 0 )) || { skipped=$((skipped + bad)); continue; }
    included+=("${good[@]}")
    if (( bad == 0 )); then
      ag="${ag:+$ag,}$dir"
    else
      skipped=$((skipped + bad))
      n=$((n + 1))
      mkdir "$tmp/$n"
      for f in "${good[@]}"; do
        cp -c "$f" "$tmp/$n/" 2>/dev/null || cp "$f" "$tmp/$n/"
        [[ -f "$f-wal" ]] && { cp -c "$f-wal" "$tmp/$n/" 2>/dev/null || cp "$f-wal" "$tmp/$n/"; }
      done
      ag="${ag:+$ag,}$tmp/$n"
    fi
  done
  (( skipped == 0 )) || echo "fleet-report: skipped $skipped unreadable Antigravity database(s)" >&2
  # An empty value would fall back to upstream's defaults and bring the crash back.
  [[ -n "$ag" ]] || ag="$tmp/none"
fi
jcode="$tmp/jcode"

if [[ -n "${FLEET_REPORT_DRY:-}" ]]; then
  echo "CLAUDE_CONFIG_DIR=$claude"
  echo "ANTIGRAVITY_DATA_DIR=$ag"
  printf 'antigravity db %s\n' "${included[@]+"${included[@]}"}"
  echo "JCODE_DIR=$jcode"
  exit 0
fi

if [[ -n "${FLEET_REPORT_BIN:-}" ]]; then
  bin="$FLEET_REPORT_BIN"
else
  bin="$repo/rust/target/release/ccusage"
  (cd "$repo/rust" && cargo build -q --release -p ccusage --features ccusage-core/fetch-litellm-pricing) >&2
fi

run() { env ${claude:+CLAUDE_CONFIG_DIR="$claude"} ANTIGRAVITY_DATA_DIR="$ag" "$bin" "$@"; }

last_error() {  # last_error PROGRAM: the last message in $tmp/err, never empty
  local e
  e="$(grep . "$tmp/err" | tail -1)" || true
  printf '%s' "${e:-$1 printed no error message}"
}

search_hash() {
  sed -n -e '/^fn discover_config_paths(/,/^}/p' -e '/^fn claude_config_dirs(/,/^}/p' \
    -e '/^fn load_config_value(/,/^}/p' -e '/^fn scan_config_path(/,/^}/p' \
    -e '/^    fn command_uses_named_pi_stores(/,/^    }/p' \
    "$config_rs" 2>/dev/null | shasum -a 256 | cut -d' ' -f1
}

config_files() {  # the files ccusage reads settings from when no --config is given, in order
  local dirs d
  local -a list
  if [[ -n "$claude" ]]; then dirs="$claude"               # what run() passes
  elif [[ -n "${CLAUDE_CONFIG_DIR+set}" ]]; then dirs=""    # set but empty: no Claude folders
  else dirs="$home/.config/claude,$home/.claude"
  fi
  echo "$PWD/.ccusage/ccusage.json"
  IFS=, read -r -a list <<<"$dirs"
  for d in ${list[@]+"${list[@]}"}; do
    d="${d#"${d%%[![:space:]]*}"}"  # ccusage trims each entry
    d="${d%"${d##*[![:space:]]}"}"
    [[ -z "$d" ]] || echo "$d/ccusage.json"
  done
}

# Why jcode stays out of this report. "-": this Mac has no jcode usage, so say nothing.
why=""
case "$kind" in daily|weekly|monthly|session) all_agents=1 ;; *) all_agents=0 ;; esac
if ! python3 "$repo/fitcode/jcode-to-pi.py" --out "$jcode" 2>"$tmp/err"; then
  why="its sessions could not be converted: $(last_error jcode-to-pi.py)"
else
  cat "$tmp/err" >&2
  if [[ ! -d "$jcode" ]]; then
    why="-"
  elif (( ! all_agents )); then
    why="only the all-agents daily, weekly, monthly and session reports take it, not '$kind'"
  elif (( config_given )); then
    why="--config was given, and jcode needs a --config of its own"
  elif [[ "$(search_hash)" != "$config_search_hash" ]]; then
    why="ccusage's config file search in $config_rs changed; re-check config_files in fitcode/fleet-report.sh and update config_search_hash"
  else
    while IFS= read -r f; do
      [[ ! -e "$f" ]] || { why="ccusage config file $f exists, and jcode's --config would hide it"; break; }
    done < <(config_files)
  fi
fi
if [[ -n "$why" ]]; then
  [[ "$why" == - ]] || echo "fleet-report: jcode not included ($why)" >&2
  run ${args[@]+"${args[@]}"}
  exit
fi

python3 -c 'import json, sys; json.dump({"pi": {"stores": [{"name": "jcode", "path": sys.argv[1]}]}}, sys.stdout)' \
  "$jcode" >"$tmp/config.json"
status=0
run ${args[@]+"${args[@]}"} --config "$tmp/config.json" 2>"$tmp/err" || status=$?
# A reader that stops early (`| head`) ends ccusage with SIGPIPE or a "Broken pipe" error.
if (( status != 0 )) && grep -q 'Broken pipe' "$tmp/err"; then status=141; fi
case "$status" in
  0) cat "$tmp/err" >&2; exit 0 ;;
  141) grep -v 'Broken pipe' "$tmp/err" >&2 || true; exit 0 ;;
esac
cat "$tmp/err" >&2
[[ -s "$tmp/err" ]] || echo "fleet-report: ccusage printed no error message" >&2
echo "fleet-report: ccusage failed (exit $status; jcode was added as a pi store)" >&2
exit "$status"
