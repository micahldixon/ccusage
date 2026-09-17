# fitcode — our space inside this ccusage fork

This repo is Micah's fork (`micahldixon/ccusage`) of the original ccusage project
(`ccusage/ccusage`). We pull the original author's updates in regularly.

## The rule

- **Everything we build lives in this `fitcode/` folder.** Code, notes, specs, scripts.
- **Everything outside `fitcode/` belongs to the original author. Do not edit it.**
  That includes the root `AGENTS.md`, `docs/`, `rust/`, `apps/`, and `.github/`.
  If our work seems to need a change out there, stop and ask Micah first.

Keeping to this rule means updates from the original project never clash with our work.

## Getting the original author's updates

From the repo root:

```sh
git pull --no-rebase --no-edit upstream main && fitcode/check-fence.sh && git push
```

The check stops the push if anything outside `fitcode/` has drifted from the original.

## Usage report for the whole fleet

```sh
fitcode/fleet-report.sh                          # daily, every supported agent
fitcode/fleet-report.sh monthly --since 20260901 # any ccusage arguments work
fitcode/fleet-report.sh monthly --fleet          # both Macs added together (run on the mini)
```

Use this instead of plain `ccusage`. It builds this fork with cargo on first use (no Nix
needed) and fixes these gaps on our machines:

- **All Claude accounts and Claude.app Cowork sessions are counted**, not just `~/.claude`
  (claude2/3/4 live in `~/.claude-shared` or their own folders; each Cowork session has its
  own transcript folder). Never set `CLAUDE_CONFIG_DIR` globally — Claude Code reads the same
  variable.
- **One empty Antigravity database no longer crashes the whole report.** Unusable files are
  skipped and counted in a warning.
- **jcode and dsh are counted.** ccusage has no reader for either, so `jcode-to-pi.py` / `dsh-to-pi.py` copy their usage
  records into pi's log format and ccusage prices them like pi sessions. They show up as
  `[jcode] <model>` rows, and as agent `jcode` in `--json` output. The all-agents daily,
  weekly, monthly and session reports include jcode, also with `--by-agent` or `--sections`.
  Single-agent reports and `blocks` leave it out and say so. jcode is also left out, with a
  warning, if you pass `--config` or ccusage has a config file of its own (such as
  `~/.claude/ccusage.json`), because adding jcode needs a `--config` that would hide that
  file. jcode's debug and canary sessions count too, because they are real spend: $190.07 of
  the mini's $1,116.20 jcode total for Sept 1–16, 2026.

Fleet coverage (checked 2026-09-16 on both Macs; jcode added 2026-09-17):

| Tool | Counted? |
|---|---|
| claude CLI, claude2/3/4, Claude.app Code, Claude.app Cowork | Yes (Code tab writes to `~/.claude/projects`) |
| codex CLI, ChatGPT.app Codex mode | Yes (both use `~/.codex`) |
| copilot CLI, GitHub Copilot.app | Yes (both use `~/.copilot`) |
| Antigravity.app, CLI, IDE | Yes |
| pi, grok | Yes |
| agy (gemini) | Supported, but agy keeps no transcripts with usage |
| jcode | Yes (converted from `~/.jcode/sessions` and priced by ccusage) |
| dsh (DeepSeek Harness) | Yes (converted from `~/.dsh/sessions` and priced by ccusage) |
| Cursor (agents, IDE, cursor-agent) | Yes, from Cursor's account usage API (not local files). Charged dollars are `chargedCents/100`. |
| ChatGPT.app Work mode | No: no token usage stored locally |
| forge-agent | No data found on either Mac |

Each Mac reports only its own logs. For the fleet total, run the report on the mini with
`--fleet` (anywhere in the arguments): it runs the same report on the MacBook over ssh and adds
the two together, as one line per period with each Mac and the total, or as one combined report
with `--json`. The two reports run at the same time. If the mini gives up early (its own report
fails, or it's interrupted), it stops asking the MacBook right away, but the MacBook's own report
keeps running to completion on its own and its result is thrown away. The MacBook must be awake,
and both Macs must be on the same commit with no uncommitted changes to the `fitcode/` scripts, `rust/` or
`flake.lock`; otherwise it stops and says why instead of showing a partial total. Both Macs use
the mini's time zone unless you pass `--timezone`. `--fleet` adds up daily, weekly and monthly
reports only, jcode included. A tool missing from one Mac's report for a period simply had no
use on that Mac then.

## Spend history Google Sheet

The live view is [Fitcode agent spend history](https://docs.google.com/spreadsheets/d/1on7v_bYdEmb2UXIuWpDuYTLZ-JPFOojJrqmvlOtnK6Q/edit):
**Dashboard** (prune: shop total, keep/cut, charts), **Master** (one row per month / machine / source / family / model / effort / spend), **ChartData** (ignore; feeds the charts). Cursor is a source on Master, machine `account` — it cannot be split Mini vs MacBook.

```sh
python3 fitcode/cursor-usage.py --live --json > /tmp/cursor-usage.json
bash fitcode/fleet-report.sh monthly --json --offline --by-agent > /tmp/fleet-mini.json
# same command on the MacBook → /tmp/fleet-macbook.json
python3 fitcode/export-agent-spend-sheet.py --mini-json /tmp/fleet-mini.json --macbook-json /tmp/fleet-macbook.json --cursor-json /tmp/cursor-usage.json --json > /tmp/spend-sheet.json
gog --account micah@fitcode.dev --no-input sheets batch-update 1on7v_bYdEmb2UXIuWpDuYTLZ-JPFOojJrqmvlOtnK6Q --data-json @/tmp/spend-sheet.json
```

## Setup (already done on the Mac mini and the MacBook)

- `origin` = our fork, pushes over SSH.
- `upstream` = the original project, with pushing disabled.

A new machine needs:

```sh
git clone https://github.com/micahldixon/ccusage.git
cd ccusage
git remote set-url --push origin git@github.com:micahldixon/ccusage.git
git remote add upstream https://github.com/ccusage/ccusage.git
git remote set-url --push upstream DISABLED
```

## Files here

- `check-fence.sh` — the safety check above.
- `test-check-fence.sh` — proves the check catches a broken fence. Run it after editing the check.
- `fleet-report.sh` — the fleet usage report above.
- `test-fleet-report.sh` — proves its account and database selection. Run it after editing the report.
- `test-fleet-mode.sh` — proves its jcode wiring and the `--fleet` safety checks. Run it after editing the report.
- `jcode-to-pi.py` — copies jcode usage into pi's log format for the report.
- `test-jcode-to-pi.sh` — proves the copy follows jcode's file and token rules. Run it after editing the converter.
- `merge-reports.py` — adds the two Macs' JSON reports into the fleet total.
- `test-merge-reports.sh` — proves the adding up. Run it after editing the merge.
- `cursor-usage.py` — pulls Cursor billed events (live API or a fixture file) and sums them by day.
- `test-cursor-usage.sh` — proves cents-to-dollars, dates, and that emails stay out of the JSON.
- `export-agent-spend-sheet.py` — turns that JSON into a Google Sheets payload.
- `test-export-agent-spend-sheet.sh` — proves the payload shape and a deliberate breakage.
- `dsh-to-pi.py` — copies DeepSeek Harness usage into pi's log format for the report.
- `test-dsh-to-pi.sh` — proves chunks are ignored and a missing dsh folder is harmless.
- `specs/` — our design notes for work built on ccusage.
