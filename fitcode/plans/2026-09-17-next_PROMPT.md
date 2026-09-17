# MAIN — run this session here

Owning workspace: the ccusage fork on the **Mac mini**.

```zsh
cd -- '/Users/fitcode/dev-tools/ccusage'
```

Read `fitcode/README.md` and `fitcode/plans/2026-09-17-spend-sheet-watchlist.md` first.

## Do not rebuild the spend sheet

That work shipped this session. Live view:

https://docs.google.com/spreadsheets/d/1on7v_bYdEmb2UXIuWpDuYTLZ-JPFOojJrqmvlOtnK6Q/edit

Dashboard = prune. Master = one row per month / machine / source / family / model / effort / spend. ChartData feeds charts; ignore it. Cursor is source `cursor`, machine `account`. dsh is in the fleet report.

Both Macs should already be on `bc9e255b`. Confirm with `git rev-parse --short HEAD` here and on macbook. Do not re-litigate jcode. The old ticket `fitcode/plans/2026-09-16-jcode-reader-and-fleet-total_PROMPT.md` is HOLD OFF on purpose.

## First action

Micah always wants original-author updates before new fitcode work.

```zsh
git pull --no-rebase --no-edit upstream main && fitcode/check-fence.sh && git push
```

Stop if the fence is broken (exit 1). Exit 2 means pull first; that command is the pull.

## Then this session's job

Run the context-overhead brainstorm. Do not write product code.

Paste and follow:

`fitcode/specs/2026-09-16-context-overhead-explorer-ideation_PROMPT.md`

It turns `fitcode/specs/2026-09-16-context-overhead-explorer-ideation.md` into a design decision. All new docs stay in `fitcode/`. Stop and ask Micah before any public/upstream work or a new top-level command.

## Optional only if he asks

Watchlist leftovers (not this prompt unless he says so): ChatGPT Work, agy, forge-agent still have no bill; Master does not yet have tokens/cache/headless; keep/cut on Dashboard is a heuristic.
