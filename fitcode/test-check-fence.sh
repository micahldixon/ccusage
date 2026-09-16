#!/usr/bin/env bash
# Self-test for check-fence.sh: builds a throwaway repo, breaks the fence on
# purpose, and fails if the check does not notice.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check-fence.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

expect() {
  local want="$1" label="$2" got
  FENCE_BASE=refs/test/upstream bash "$script" >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then
    echo "ok   $label (exit $got)"
  else
    echo "FAIL $label: expected exit $want, got $got"
    failures=$((failures + 1))
  fi
}

cd "$tmp"
git init -q
git config user.email test@example.com
git config user.name test
echo upstream > owned.txt
git add owned.txt
git commit -qm upstream
git update-ref refs/test/upstream HEAD

mkdir fitcode
echo ours > fitcode/note.md
git add fitcode
git commit -qm fork
expect 0 "change inside fitcode/ is allowed"

echo edited > owned.txt
expect 1 "uncommitted edit to an upstream file is caught"

git commit -qam "edit upstream file"
expect 1 "committed edit to an upstream file is caught"

git revert --no-edit HEAD >/dev/null
echo new > added-outside.txt
git add added-outside.txt
git commit -qm "add file outside fence"
expect 1 "new file outside fitcode/ is caught"

git rm -q added-outside.txt
git commit -qm cleanup
expect 0 "fence intact again after cleanup"

git checkout -q -b upstream-ahead refs/test/upstream
echo newer > owned.txt
git commit -qam "upstream moves ahead"
git update-ref refs/test/upstream HEAD
git checkout -q -
expect 2 "unmerged upstream updates are reported"

if (( failures > 0 )); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all fence checks passed"
