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
```

Use this instead of plain `ccusage`. It builds this fork with cargo on first use (no Nix
needed) and fixes two gaps on our machines:

- **All Claude accounts and Claude.app Cowork sessions are counted**, not just `~/.claude`
  (claude2/3/4 live in `~/.claude-shared` or their own folders; each Cowork session has its
  own transcript folder). Never set `CLAUDE_CONFIG_DIR` globally — Claude Code reads the same
  variable.
- **One empty Antigravity database no longer crashes the whole report.** Unusable files are
  skipped and counted in a warning.

Fleet coverage (checked 2026-09-16 on both Macs):

| Tool | Counted? |
|---|---|
| claude CLI, claude2/3/4, Claude.app Code, Claude.app Cowork | Yes (Code tab writes to `~/.claude/projects`) |
| codex CLI, ChatGPT.app Codex mode | Yes (both use `~/.codex`) |
| copilot CLI, GitHub Copilot.app | Yes (both use `~/.copilot`) |
| Antigravity.app, CLI, IDE | Yes |
| pi, grok | Yes |
| agy (gemini) | Supported, but agy keeps no transcripts with usage |
| jcode | No reader yet; its session files do record token usage |
| Cursor (agents, IDE, cursor-agent), ChatGPT.app Work mode | No: no token usage stored locally |
| forge-agent | No data found on either Mac |

Each Mac only reports its own local logs; add the two for a fleet total. A tool missing from
one Mac's report for a period simply had no use on that Mac then.

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
- `specs/` — our design notes for work built on ccusage.
