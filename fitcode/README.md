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
- `specs/` — our design notes for work built on ccusage.
