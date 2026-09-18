# MAIN — run this session here

Owning workspace: the ccusage fork on the **Mac mini**.

```zsh
cd -- '/Users/fitcode/dev-tools/ccusage'
```

Next Atlas: Claude family, Fable 5.1 (or Opus 5), effort high. Sparks: Sonnet 5 medium for
implementation and review, Haiku 4.5 low for fixture and format checks.

Read first: `fitcode/README.md`, then
`fitcode/specs/2026-09-17-context-overhead-capture-design.md` (approved design), then `fitcode/plans/2026-09-17-spend-sheet-watchlist.md`.

## First action

```zsh
git pull --no-rebase --no-edit upstream main && fitcode/check-fence.sh && git push
```

Stop if the fence is broken (exit 1). Then confirm both Macs match:
`git rev-parse --short HEAD` here and `ssh macbook 'cd ~/dev-tools/ccusage && git rev-parse --short HEAD'`.
The MacBook also carries an untracked `docs/plans/` folder outside the fence; it is not ours,
leave it and mention it once.

## Then: build it

The design is approved (option A; both gates answered "no": no new top-level `ccusage`
command, no leaked-prompt corpus). Do not re-litigate it; if implementation finds a real
problem, update the design doc first and say so.

This is non-trivial code (a new script plus test), so it belongs in a dedicated worktree. Ask
Micah explicitly to authorize the worktree and branch (`feat/context-overhead-capture`), then
follow `sc instructions worktree`; never hand-roll one. Implement per the design's Required
Changes and Validation sections with the break-tests written first. Verification commands:
`bash fitcode/test-context-overhead.sh`, `fitcode/check-fence.sh`, and one live probe on the
mini compared against an interactive `/context` in the same directory. Expected artifact: a
branch with the script, test, README section, and the live-smoke numbers in the commit message.

First follow-up spike, cheap and independent: does `copilot -p "/context"` return Copilot's
breakdown non-interactively on this Mac? Its answer decides whether Copilot joins v1.

## Stop conditions

Stop and ask Micah before any edit outside `fitcode/`, any new public command, any external
dependency, or any change to the explorer HTML in `~/dev-tools/agents-mgmt`.

## Optional only if he asks

Spend-sheet watchlist leftovers: ChatGPT Work, agy, forge-agent have no bill; Master lacks
tokens/cache/headless columns; keep/cut on Dashboard is a heuristic.
