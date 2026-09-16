#!/usr/bin/env bash
# Fence check for the micahldixon/ccusage fork.
#
# Everything outside fitcode/ belongs to upstream (ccusage/ccusage) and must stay
# byte-identical to upstream/main. This lists any tracked file outside fitcode/
# that differs from upstream, committed or not.
#
# Exit 0: fence intact. Exit 1: files outside fitcode/ differ from upstream.
# Exit 2: upstream has updates this checkout has not merged yet (pull first).
# Override the upstream ref with FENCE_BASE (used by the self-test).
set -euo pipefail

base="${FENCE_BASE:-upstream/main}"
cd "$(git rev-parse --show-toplevel)"

if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "fence: cannot find $base. Run: git fetch upstream" >&2
  exit 2
fi

if ! git merge-base --is-ancestor "$base" HEAD; then
  echo "fence: upstream has updates not merged here yet. Run: git pull --no-rebase --no-edit upstream main" >&2
  exit 2
fi

changed="$(git diff --name-status "$base" -- . ':(exclude)fitcode')"
if [[ -n "$changed" ]]; then
  echo "fence: BROKEN. These upstream-owned files differ from $base:" >&2
  echo "$changed" >&2
  echo "Move your change into fitcode/, or undo it: git checkout $base -- <file>" >&2
  exit 1
fi

echo "fence: intact. Only fitcode/ differs from $base."
