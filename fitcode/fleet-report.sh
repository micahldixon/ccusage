#!/usr/bin/env bash
# Fleet usage report: runs this fork's ccusage over every coding agent it supports,
# with two fixes the stock command lacks on our machines:
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
#
# Usage: fitcode/fleet-report.sh [ccusage arguments]   e.g. monthly --since 20260901
# Builds rust/target/release/ccusage with cargo on first use (no Nix needed).
# FLEET_REPORT_DRY=1 prints the computed settings instead of running (used by the test).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
home="${HOME:?}"

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

claude="${CLAUDE_CONFIG_DIR:-$(claude_dirs)}"

ag="${ANTIGRAVITY_DATA_DIR:-}"
included=()
if [[ -z "$ag" ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-report-ag.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
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

if [[ -n "${FLEET_REPORT_DRY:-}" ]]; then
  echo "CLAUDE_CONFIG_DIR=$claude"
  echo "ANTIGRAVITY_DATA_DIR=$ag"
  printf 'antigravity db %s\n' "${included[@]+"${included[@]}"}"
  exit 0
fi

bin="$repo/rust/target/release/ccusage"
(cd "$repo/rust" && cargo build -q --release -p ccusage --features ccusage-core/fetch-litellm-pricing)

env ${claude:+CLAUDE_CONFIG_DIR="$claude"} ANTIGRAVITY_DATA_DIR="$ag" "$bin" "$@"
