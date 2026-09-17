# Plan — count jcode, and add a fleet-wide total

Handoff: `2026-09-16-jcode-reader-and-fleet-total_PROMPT.md`. Resume at the first unchecked box.
All work stays in `fitcode/`; run `fitcode/check-fence.sh` before every push.

## Decisions (Micah, 2026-09-17)

1. **jcode reader = a converter inside `fitcode/`.** It rewrites jcode usage records into pi's
   log format in a temporary folder; a jcode-only ccusage run prices them; the wrapper relabels
   those rows as agent `jcode` and merges them into the report. Rejected: an upstream Rust
   adapter (public, needs approval, nothing counted meanwhile), a script with its own price
   list (prices drift from ccusage's), a private adapter outside `fitcode/` (breaks the fence).
   Micah asked for the spike test early: Phase 0 gates everything else.
   **Implementation change (Atlas, 2026-09-17, after review):** the converted folder is passed
   to ccusage as a pi named store called `jcode` (temporary `--config`) on every all-agents
   report, table and JSON alike. Measured: ccusage then reports agent `jcode` with
   `[jcode] X` models for daily, weekly, monthly and session, at the same $1,116.20. This
   replaces the separate `ccusage pi` run plus `merge-reports.py --as jcode`, which only
   covered daily/monthly and mis-filtered short date flags (`-s=`) by $261.94. The decision
   itself (converter in `fitcode/`, priced by ccusage, jcode under its own name) is unchanged.
   `merge-reports.py` remains for the fleet total.
2. **Fleet total = live pull from the mini.** One wrapper option on the mini runs the same
   report on the MacBook over `ssh -o BatchMode=yes macbook`, refuses on unreachable host or a
   commit mismatch, pins the time zone on both sides, and sums with the same merge step.
   Rejected: scheduled snapshots (stale, two background jobs), manual adding. Flip condition:
   if the MacBook is usually away when the number is wanted, revisit snapshots.

## Facts this plan rests on (re-derived by the session Scribe, 2026-09-17)

- jcode sessions: `~/.jcode/sessions/*.json` (one JSON object per session, per-request
  `token_usage` on assistant messages, unique message `id`, per-message `timestamp`,
  session-level `model`/`provider_key`). `.bak` is an older strict-prefix snapshot: skip it.
  `*.journal.jsonl` holds appended messages not yet in `.json` (no id overlap): read it.
  `session-metadata-v1.sqlite3` is an index with no usage.
- jcode calls providers over its own HTTP client; Claude windows show no overlap with
  `~/.claude/projects`. No OpenAI overlap with `~/.codex` either (checked in Phase 0).
- OpenAI-provider `input_tokens` include cached tokens; Claude's do not (confirmed in Phase 0).
- MacBook has 12 jcode sessions and no September usage. Both Macs use `America/Indiana/Indianapolis`. The MacBook
  cannot reach the mini over ssh today.
- Baseline at `00f02887`: Sept mini $13,653.94, MacBook $144.84; all time mini $33,105.04,
  MacBook $20,053.64. Mini jcode, Sept: about 1.3B tokens, unpriced.

## Phase 0 — spike (gate)

- [x] Pilot proves the pi-format route: isolated jcode-only run, token totals reconcile with the
      hand counts (octopus, crab, duck, frog journal), cost is non-zero per model, the
      input-token rule per provider is settled, OpenAI/Codex overlap verdict, `--by-agent`
      merge shape understood. No-go → stop and re-decide with Micah.
      **Result (2026-09-17, attempt 2): Go.** Findings the build must honour:
      - `ccusage pi <kind> --json --pi-path DIR` reads only `DIR` (recursive `*.jsonl`) and,
        in the default cost mode, prices records that carry no cost from the model name.
        Its rows name the period `month`/`date`/…, have no `agent`, and prefix every model
        with `[pi] `.
      - jcode timestamps have 6 fractional digits; ccusage silently drops them. Truncate to 3.
      - OpenAI-provider `input_tokens` include cached tokens (cache read never exceeds input
        in 5,212 records); Claude's do not (cache read exceeds input in 92%). For `openai*`
        (and defensively `grok-build`) write input minus cache read; Claude unchanged.
      - pi's dedupe is a whole-record fingerprint that includes the session id, not a
        message id; the converter must dedupe by message id itself.
      - No OpenAI overlap with `~/.codex` for the sessions checked.
      - Sept mini jcode, previously uncounted: $1,116.20; sessions marked debug/canary are
        $190.07 of it (17%). Decision: count them (real spend); record the share.
      - Model names: relabel `[pi] X` to `[jcode] X`, never bare `X` — all 7 jcode models
        collide with Claude Code / Codex buckets otherwise (ccusage prefixes pi for the same
        reason).

## Phase 1 — shared merge step

- [x] Self-test first (`fitcode/test-merge-reports.sh` or folded into the existing test):
      sums two reports by period/agent/model, relabels an input's agent, keeps `totals` equal
      to the sum of rows, handles `--by-agent` nesting. Break each rule on purpose and show the
      test fails.
- [x] `fitcode/merge-reports.py` (Python 3 stdlib) passes it. (26 checks; 18 of 19
      deliberate breakages caught, the 19th only changes an error message. Its `--as AGENT`
      relabel was later removed with the named-store change; it now only adds machines
      together, 26 checks after the fixes. `ccusage pi` has no weekly report.)

## Phase 2 — jcode converter and wrapper wiring

- [x] Self-test first with fixture sessions: `.bak` ignored, journal read, duplicate ids counted
      once, OpenAI cached-input rule, `cache_creation_input_tokens` → cache write, zero-token
      and `mock` rows harmless. Break each rule on purpose and show the test fails.
- [x] `fitcode/jcode-to-pi.py` passes it. (28 checks; all 11 deliberate breakages caught.
      No usage record is copied into a second session on the mini, so per-session id
      dedupe is enough. Full mini run 0.44 s; Sept $1,116.20, same as the trial.)
- [x] `fleet-report.sh` runs the jcode-only report and merges it for `--json`; decide and
      test how table output shows jcode. (Superseded by the named-store route above: one
      ccusage run, table and JSON alike; jcode is skipped with a warning when `--config` is
      given, a ccusage config file exists, or upstream's config search changes (hash guard).
      Two Opus reviews; all findings fixed.)

## Phase 3 — fleet option

- [x] Self-test first with a fake remote: unreachable host fails loudly, commit mismatch fails,
      time zone passed to both sides, fleet total equals the sum of the parts.
      (`fitcode/test-fleet-mode.sh`, 192 checks, every rule broken on purpose once.)
- [x] Implement the option in `fleet-report.sh`. (Both reports run at once, about 54 s;
      refuses on unreachable host, commit mismatch, uncommitted code or `flake.lock`, same
      hostname; forwarded arguments survive the remote zsh; TERM stops both sides. After an
      early exit the other Mac's report finishes on its own and is discarded.)

## Phase 4 — verify and ship

- [ ] `bash fitcode/test-fleet-report.sh`, `bash fitcode/test-check-fence.sh` (and any new test)
      pass on both Macs.
- [ ] Real runs on both Macs list `jcode` where used; jcode figures reconcile with the hand
      count; fleet total equals the two per-machine totals for the same range.
- [x] `fitcode/README.md` coverage table and usage updated.
- [ ] Commit, `fitcode/check-fence.sh`, push; MacBook pulled to the same commit.
- [ ] Plain-English before/after report to Micah.
