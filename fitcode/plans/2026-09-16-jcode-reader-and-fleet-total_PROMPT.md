# MAIN — run this session here

Owning workspace: the ccusage fork on the **Mac mini** (`hostname` must print `mac-mini.local`).

```zsh
cd -- '/Users/fitcode/dev-tools/ccusage'
```

# Handoff — count jcode, and add a fleet-wide total

## Goal

Two additions to the fork's fleet usage report (`fitcode/fleet-report.sh`):

1. **Count jcode.** It is the last tool on Micah's fleet list that records token usage locally
   but has no ccusage reader.
2. **One fleet-wide number.** Each Mac reports only its own logs today; Micah wants a single total
   covering the Mac mini and the MacBook.

## Read first

- `fitcode/README.md` — the fence rule (all our work stays in `fitcode/`; everything else must stay
  identical to upstream), the update command, and the fleet coverage table.
- `fitcode/fleet-report.sh` and `fitcode/test-fleet-report.sh` — the current wrapper and its self-test.
- Root `AGENTS.md` and `rust/adapters/AGENTS.md` — upstream's adapter conventions. Read them to
  understand the data model even though we cannot edit upstream files.

## Facts established 2026-09-16 (re-verify, do not trust)

- jcode data: `~/.jcode/sessions/` (very large; a plain `ls | sort` timed out after 2 minutes, so
  use `find … -newermt … -print -quit` style sampling) and `~/.jcode/session-metadata-v1.sqlite3`.
  A sampled session file (`session_*.bak`) held `token_usage` objects with `input_tokens`,
  `output_tokens`, and `cache_read_input_tokens`. Its model/provider/timestamp fields and the
  live (non-`.bak`) file format are unconfirmed.
- jcode routes to several providers (Claude, OpenAI, Gemini, Grok, Antigravity per its auth
  files). Check whether those calls also land in another tool's logs before counting them, or
  the fleet total double-counts.
- Neither Mac has Nix. `fleet-report.sh` builds with
  `cargo build --release -p ccusage --features ccusage-core/fetch-litellm-pricing` in `rust/`.
- Latest measured totals (`fitcode/fleet-report.sh monthly --json`): Mac mini Sept ≈ $13.5k,
  all time ≈ $33.0k; MacBook Sept ≈ $145, all time ≈ $20.1k. The MacBook is reachable read-only
  with `ssh -o BatchMode=yes macbook`.

## Decisions to make with Micah (use the decision-presentation format)

1. **Where the jcode reader lives.** Options include a fitcode-only reader (a script that emits
   ccusage-compatible JSON rows merged by the wrapper), or an upstream adapter proposed to
   `ccusage/ccusage`. The upstream route is public and needs Micah's explicit OK before any issue
   or PR. Language choice follows the policy in root `AGENTS.md`.
2. **How the fleet total is gathered.** For example, the mini runs the MacBook's report over SSH
   and sums the two, versus each Mac writing a dated JSON snapshot somewhere both can read.
   The mini is the primary machine (`~/dev-tools/CANONICAL.md`).

## Constraints

- Nothing outside `fitcode/` changes. Run `fitcode/check-fence.sh` before every push.
- The report must never double-count. Deduplicate by real path, as `fleet-report.sh` already
  does for Claude folders.
- Every new selection or merge rule gets a self-test that fails when the rule is broken on
  purpose. Prove the failure; don't assume it.
- Do not set `CLAUDE_CONFIG_DIR` globally.
- No worktree is needed unless the reader grows beyond a small script; if it does, ask first.

## Verification

- `bash fitcode/test-fleet-report.sh` and `bash fitcode/test-check-fence.sh` pass on both Macs.
- A real `fitcode/fleet-report.sh monthly --json --since <date>` run on both Macs lists `jcode`
  where it was used, and the jcode figures reconcile with a hand count from a few session files.
- The fleet total equals the sum of the two per-machine totals for the same date range.
- `fitcode/README.md` coverage table updated.

## Expected result

Committed and pushed to `origin` (Micah's fork), both Macs pulled to the same commit, and a
short plain-English report with the before and after totals.
