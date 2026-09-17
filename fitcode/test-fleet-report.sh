#!/usr/bin/env bash
# Self-test for fleet-report.sh's selection logic (no ccusage build needed). Builds a fake
# home with the traps we hit for real, and fails if the script stops handling any of them.
# FLEET_REPORT_SCRIPT=path tests another copy of the report (used to break it on purpose).
set -uo pipefail

script="${FLEET_REPORT_SCRIPT:-$(cd "$(dirname "$0")" && pwd)/fleet-report.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
home="$tmp/home"
failures=0

check() {
  if grep -qF -- "$2" <<<"$out"; then want=yes; else want=no; fi
  if [[ "$want" == "$1" ]]; then echo "ok   $3"; else echo "FAIL $3"; failures=$((failures + 1)); fi
}

mkdir -p "$home/.claude-shared/projects" "$home/.claude-account2" \
         "$home/.gemini/antigravity/conversations" "$home/.gemini/antigravity-cli/conversations"
# MacBook shape: primary projects is a symlink into the shared pool.
mkdir -p "$home/.claude"
ln -s "$home/.claude-shared/projects" "$home/.claude/projects"
ln -s "$home/.claude-shared/projects" "$home/.claude-account2/projects"

sqlite3 "$home/.gemini/antigravity-cli/conversations/good.db" \
  "create table gen_metadata (idx integer primary key, data blob not null)"
: > "$home/.gemini/antigravity/conversations/empty.db"
sqlite3 "$home/.gemini/antigravity/conversations/other.db" "create table steps (id integer)"

out="$(env -u CLAUDE_CONFIG_DIR -u ANTIGRAVITY_DATA_DIR HOME="$home" FLEET_REPORT_DRY=1 \
       bash "$script" 2>&1)"

check yes "CLAUDE_CONFIG_DIR=$home/.claude" "primary Claude account is included"
check no  ".claude-shared"                  "shared pool aliasing primary is counted once"
check no  ".claude-account2"                "account symlinked into the same pool is counted once"
check yes "antigravity db $home/.gemini/antigravity-cli/conversations/good.db" \
                                            "usable Antigravity database is kept"
check yes "ANTIGRAVITY_DATA_DIR=$home/.gemini/antigravity-cli/conversations" \
                                            "clean folder is read in place"
check no  "empty.db"                        "empty Antigravity database is skipped"
check no  "other.db"                        "database without gen_metadata is skipped"
check no  "$home/.gemini/antigravity/conversations" "folder with no usable database is not read"
check yes "skipped 2 unreadable"            "skipped databases are reported"
check yes "JCODE_DIR=${TMPDIR:-/tmp}/fleet-report-ag." "jcode is converted into the temp folder"

# A folder mixing usable and broken databases is read from clones, never in place.
sqlite3 "$home/.gemini/antigravity/conversations/desk.db" \
  "create table gen_metadata (idx integer primary key, data blob not null)"
out="$(env -u CLAUDE_CONFIG_DIR -u ANTIGRAVITY_DATA_DIR HOME="$home" FLEET_REPORT_DRY=1 \
       bash "$script" 2>&1)"
check yes "antigravity db $home/.gemini/antigravity/conversations/desk.db" \
                                            "usable database in a mixed folder is kept"
check no  ",$home/.gemini/antigravity/conversations" "mixed folder is not read in place"
check yes "ANTIGRAVITY_DATA_DIR=${TMPDIR:-/tmp}/fleet-report-ag." "mixed folder is read from a temp copy"

# Claude.app Cowork sessions each carry their own transcript folder.
cowork="$home/Library/Application Support/Claude/local-agent-mode-sessions/org/acct/local_abc/.claude"
mkdir -p "$cowork/projects"
out="$(env -u CLAUDE_CONFIG_DIR -u ANTIGRAVITY_DATA_DIR HOME="$home" FLEET_REPORT_DRY=1 \
       bash "$script" 2>&1)"
check yes "$cowork" "Claude.app Cowork session is included"

# Mini shape: primary is a real directory, so the shared pool must be added.
rm "$home/.claude/projects"; mkdir "$home/.claude/projects"
out="$(env -u CLAUDE_CONFIG_DIR -u ANTIGRAVITY_DATA_DIR HOME="$home" FLEET_REPORT_DRY=1 \
       bash "$script" 2>&1)"
check yes "CLAUDE_CONFIG_DIR=$home/.claude,$home/.claude-shared" "separate shared pool is added"

if (( failures > 0 )); then echo "$failures check(s) failed"; exit 1; fi
echo "all fleet-report checks passed"
