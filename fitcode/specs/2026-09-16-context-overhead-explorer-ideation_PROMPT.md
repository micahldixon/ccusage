---
slug: 2026-09-16-context-overhead-explorer-ideation
date: 2026-09-16
resume_key: quick-d9498
---

MAIN — run this session here
`cd -- '/Users/fitcode/dev-tools/ccusage'`

> If your session already shows the active plan is `quick-d9498`, resume it directly instead of pasting this.

## Active Plan State

No active plan is recorded for this repo — `/Users/fitcode/dev-tools/ccusage` is not forge-enrolled
(no `.planning/STATE.md`, no `docs/forge-ledger.json`, no `docs/a-flaw-report-inbox/` or
`docs/a-idea-inbox/`, no `docs/plans/` directory at all). It runs its own `AGENTS.md`
skill-routing convention instead (`development`, `rust`, `typescript`, `agent-sources`, `docs`,
etc.) — read that file before touching anything. Nothing was filed to any backlog this session.

Existing artifact: `fitcode/specs/2026-09-16-context-overhead-explorer-ideation.md` — an
ideation-stage scoping doc (problem, prior art, open questions, explicit non-goals), written by a
prior session. It is committed in the fork, and nothing beyond it has been built.

## Committed Work Since Session Start

No commits since session start.

## Outstanding TODO / Uncommitted State

None. Both notes are committed.

No `TODO`/`FIXME`/`XXX` markers in the touched file.

## Continuation Prompt — Paste After /clear

Read `fitcode/specs/2026-09-16-context-overhead-explorer-ideation.md` in this repo first — it's the
full scoping doc for what you're about to brainstorm. Short version: this repo (`ccusage`) already
parses *realized* agent-CLI session logs across 17+ adapters, but nothing here (or, as far as one
session's web research found, anywhere) measures the *cold-start* token overhead a coding-agent
CLI pays before the user types anything — system prompt, tool schemas, deferred/MCP tool stubs,
skill descriptors — broken out by category, across multiple CLIs. Two pieces of prior art exist
and are cited in the doc: a hand-built HTML visualization fed by Claude Code's real `/context`
output, and the `x1xhlol/system-prompts-and-models-of-ai-tools` corpus as raw material for CLIs
that lack an equivalent live introspection command.

Your job: run `superpowers:brainstorming` on this idea to turn the ideation doc's open questions
into an actual decision — not to start implementing. The open questions that most need resolving
first (all detailed in the doc):

1. Where this lives in the repo — this doesn't fit `rust/adapters/<agent>` as-is, since that's
   reserved for source-specific *usage-log* behavior, not cold-start composition from a different
   data source.
2. Language choice per this repo's own stated policy (Rust vs Nushell vs Babashka vs TypeScript —
   read `AGENTS.md`'s Policy section before assuming Rust).
3. Whether a `measured` (live introspection, e.g. Claude Code's `/context`) vs `estimated`
   (leaked-corpus-derived) provenance distinction gets surfaced in any report, the way the
   existing HTML explorer already tags it.
4. Which of the 17+ already-adapted CLIs actually expose a live equivalent to `/context` — this
   is unresearched and determines how much of the multi-CLI scope can ever be `measured` vs
   `estimated`.
5. Corpus vendoring vs live fetch, if the x1xhlol repo ends up used as a source.

This repo is Micah's fork. All our work lives in `fitcode/` and nothing outside it may be edited;
read `fitcode/README.md` first. That settles where the design doc goes, and any code that would
need to change upstream-owned files is a decision to bring to the user.

Read `AGENTS.md` and `docs/AGENTS.md` in this repo before proposing any location or format — this
is a foreign-to-you-until-now upstream fork with its own conventions (Rust-first adapters,
`docs/superpowers/specs/<date>-<slug>-design.md` for the author's decided designs — see
`docs/superpowers/specs/2026-07-28-grok-env-only-path-design.md` as the format precedent). Do not write code.
Do not create a worktree yet — if the brainstorm concludes this is worth building, follow this
repo's own non-trivial-work isolation practice at that point, not before.

Land the outcome as `fitcode/specs/2026-09-16-context-overhead-<slug>-design.md` (or a doc explicitly
titled otherwise if the brainstorm changes the framing), following the existing Grok design doc's
structure (Context / Decision / Data Flow / Required Changes / Validation / Documentation Impact /
Out of Scope / Compatibility).

Stop and ask the user if the brainstorm surfaces a decision with real cost/reversibility stakes
(e.g. committing to a corpus-fetch dependency, or a new top-level CLI command) rather than
resolving it unilaterally.
