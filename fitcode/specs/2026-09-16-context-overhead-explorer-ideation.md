# Cold-Start Context Overhead — Ideation

**Status: brainstormed 2026-09-17 → see `2026-09-17-context-overhead-capture-design.md` (draft awaiting review). Not built.** This scopes the problem and
the open questions a real brainstorming session (`superpowers:brainstorming`) needs to resolve
before a `fitcode/specs/*-design.md` gets written.

## Problem

`ccusage` already answers "what did this agent CLI actually spend, session by session" by
parsing each adapter's local log format (`rust/adapters/<agent>`). It does not answer a
different, narrower question: **what does a given agent CLI spend before the user types
anything** — system prompt, built-in tool schemas, deferred/MCP tool stubs, and skill/plugin
descriptors, broken out by category. That's a one-time "cold start tax" per session, not a
realized-usage number, and today nothing in this repo (or, as far as an adversarial web check
this session found, anywhere else) measures or reports it in a structured, cross-CLI way.

## Why this surfaced

A manual, estimated breakdown of Claude Code's own cold-start overhead was produced by hand in a
separate session (word-count-based, explicitly caveated as imprecise — no tokenizer access to the
live context). That prompted the question this doc scopes: can `ccusage` — which already has
adapters for nearly every major coding-agent CLI (`claude`, `codex`, `gemini`, `opencode`, `amp`,
`goose`, `copilot`, `pi`, `grok`, `qwen`, `kimi`, `droid`, `kilo`, `hermes`, `codebuff`,
`antigravity`, `openclaw`, `zcode`) — grow a companion capability that does this properly instead
of by hand.

## Prior art found (both already exist, neither solves this alone)

1. **`/Users/fitcode/dev-tools/agents-mgmt/context-overhead-explorer.html`** — a standalone,
   hand-built interactive zoomable-donut visualization. Its `DATA` is a **hardcoded JSON
   snapshot**, and every leaf is tagged `"measured":true` — it was populated from Claude Code's
   real `/context` slash command output (exact per-MCP-tool, per-skill, system-prompt, and
   memory-file token counts), not estimated. It proves the *visualization* is worth having and
   that *live, exact* introspection is possible for at least one CLI, but it is static (one
   captured session, not a live/repeatable pipeline) and lives outside this repo with no
   generator script behind it.
2. **`github.com/x1xhlol/system-prompts-and-models-of-ai-tools`** — an actively maintained
   (140k+ star), broad-coverage archive of leaked raw system prompts and tool-schema text for
   30+ coding agents (Cursor, Windsurf, Devin, v0, Replit, etc.). Checked this session against
   the closest alternatives (jailbreak/prompt-injection archives); those catalog extraction
   technique, not curated prompt corpora, so this repo is the strongest available option in its
   genre — but it is plain per-tool markdown/text, not structured data, and it has to be
   tokenized and categorized (system prompt vs tool schema vs skill text) by hand per product,
   same as the manual Claude Code estimate that started this.

Neither combines with the other today. `ccusage`'s adapters are a third, related-but-different
thing: they parse *realized session logs*, which is a different data source and lifecycle again
(no external corpus to sync, no "cold start" concept at all).

## What this might unlock, if built

- Reproduce the Claude Code cold-start breakdown as a **repeatable, exact** report instead of a
  one-off hand-estimate — likely by shelling out to `/context` (or an equivalent introspection
  path, if one exists) rather than re-deriving it by word count.
- Extend the same categorized breakdown to other CLIs `ccusage` already has adapters for, using
  the x1xhlol corpus (or a per-CLI live-introspection command, where one exists) as the source.
- Let someone compare tool-schema verbosity across products (e.g. is Claude Code's `Artifact`
  tool unusually large next to Cursor's equivalent) instead of guessing.
- Possibly replace the standalone HTML explorer with a real `ccusage`-generated report, so the
  visualization stays in sync with a live pipeline instead of a hand-captured snapshot.

## Why this is NOT the same problem `ccusage` adapters solve

| | Existing adapters | This idea |
|---|---|---|
| Data source | Local session logs (real conversations) | Live introspection command (if one exists) or a static reference corpus |
| Measures | Tokens actually billed | Tokens paid before the first user message |
| Lifecycle | Logs accumulate automatically | A reference corpus needs periodic re-sync from upstream; a live command needs no sync but may not exist per-CLI |
| Provenance | Always exact | Mixed — exact where a live command exists, estimated/manual where only a leaked-prompt corpus is available |

That data-source mismatch is the main reason this should NOT be quietly folded into the existing
adapter code path — it's a different kind of "source," not a new agent.

## Open questions for the brainstorming session

- **Where does it live in the repo?** A new top-level command/report mode (e.g. `ccusage
  overhead`), or something adjacent that reuses `ccusage-core`'s tokenizer/reporting utilities
  without touching `rust/adapters/*`? The repo's `AGENTS.md` reserves `rust/adapters/<agent>` for
  source-specific *usage log* behavior — this doesn't fit that shape as-is.
- **Language choice.** Per this repo's stated policy: Rust for CPU/memory-intensive production
  code, Nushell for small orchestration, Babashka "once automation grows a reusable data model,
  several transformation stages, substantial reporting logic, or its own unit tests." A
  corpus-fetch → categorize → tokenize → report pipeline sounds closer to the Babashka
  description than a Rust adapter — needs a real decision, not an assumption.
- **Provenance tracking.** The existing HTML explorer already distinguishes `measured` (exact,
  from `/context`) vs an implied `estimated` badge class. Any new report needs the same
  measured-vs-estimated distinction surfaced, not silently blended.
- **Per-CLI live introspection.** Claude Code has `/context`. Do any of the other 17+ adapted
  CLIs expose an equivalent live, exact breakdown command? Unresearched — this determines how
  much of the multi-CLI scope can ever be "measured" rather than "estimated from a leaked
  corpus."
- **Corpus staleness/vendoring.** If x1xhlol is used as a source for CLIs without live
  introspection, does `ccusage` vendor a pinned snapshot (reproducible, can go stale) or fetch
  live (always current, adds an external dependency this tool doesn't otherwise have)?
- **Scope of "done."** Is the goal a CLI report (`ccusage overhead claude`), a regenerated
  version of the existing standalone HTML explorer, both, or something else entirely?

## Explicit non-goals (for this ideation pass)

- No code, no new adapter, no new crate, no CLI flag — this is scoping only.
- Not replacing or modifying any existing adapter's usage-log parsing behavior.
- Not deciding the language/location question here — that's what the brainstorming session and
  eventual `fitcode/specs/*-design.md` are for.

## Suggested next step

Run `superpowers:brainstorming` in this repo (not in `agents-mgmt`, not in
`monarch-money-freelancer`) to turn the open questions above into a real design, then land a
`fitcode/specs/<date>-context-overhead-<slug>-design.md` following the format already established
by `2026-07-28-grok-env-only-path-design.md` before any implementation starts.
