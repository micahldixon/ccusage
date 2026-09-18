# Cold-Start Context Overhead Capture — Design

**Status: APPROVED by Micah on 2026-09-17 (option A).** Brainstorm outcome for
`2026-09-16-context-overhead-explorer-ideation.md`. No code has been written yet. The two
**GATE** decisions below were answered "no" with the approval: no new top-level `ccusage`
command, no leaked-prompt corpus.

## Context

`ccusage` reports what an agent CLI *spent* by reading its session logs. It has no tokenizer of
its own and no notion of the "cold-start tax": the tokens a CLI loads before the user types
(system prompt, tool schemas, MCP stubs, skills, memory files). The ideation doc left five open
questions. This session ran three recon passes (Sonnet, medium) plus one capture (Haiku) and
established the facts below; every number is from a command run on the Mac mini on 2026-09-17
unless marked *reported* (from vendor docs, cited in the recon report).

1. **Claude Code's breakdown is capturable headlessly, at zero model cost.**
   `claude -p "/context" --output-format json` (Claude Code 2.1.275) returns a JSON result whose
   `local_command` is `context`, `duration_api_ms` is 0, and whose `result` string is the same
   markdown `/context` prints interactively: a `## Context Usage` block with `**Model:**` and
   `**Tokens:** 35.7k / 200k (18%)`, a `### Estimated usage by category` table (9 rows: System
   prompt, MCP tools, MCP tools (deferred), System tools (deferred), Custom agents, Memory files,
   Skills, Messages, Free space), then `### MCP Tools` (Tool | Server | Tokens, 53 rows here),
   `### Custom Agents` (Agent Type | Source | Tokens), `### Memory Files` (Type | Path | Tokens),
   and `### Skills` (Skill | Source | Tokens, 117 rows here). The raw capture is preserved as
   `fitcode/fixtures/context-claude-2.1.275.json`. This is **undocumented** behavior: the docs
   list `/context` as interactive-only and do not include it in the headless slash-command
   allowlist.
2. **`/context` is a rounded self-report, not an exact count.** Its own heading says
   "Estimated"; values appear as `468`, `3.4k`, `~170`, `< 20`. A second, independent path
   exists: every `claude -p` model turn writes a `prompt_snapshot` attachment into the session
   transcript (`~/.claude/projects/<slug>/<session>.jsonl`) holding the raw system-prompt blocks
   and every tool's name, description and schema. Tokenizing that would give exact numbers, but
   needs a tokenizer this repo does not have (a token-counting API call or a local model).
3. **Composition is per machine, per account, per working directory.** Two captures minutes
   apart from different directories gave MCP tools (deferred) of 6k and 12.9k. Memory files
   include the project `CLAUDE.md` chain; skills and MCP servers depend on the config dir.
4. **Of 21 CLIs surveyed, five have an itemized `/context`-style command** (*reported*): Claude
   Code (verified), GitHub Copilot CLI, Google Antigravity CLI, Kilo Code CLI, Hermes Agent.
   Cursor CLI is unresolved (docs describe a breakdown tray; unclear if it reaches the terminal).
   The rest (codex, gemini, opencode, amp, goose, pi, grok, qwen, kimi, droid, codebuff,
   openclaw, zcode, jcode) expose only aggregate token counters. Correction found by the Scribe:
   `agy` (1.2.5, a Go binary at `~/.local/bin/agy` that wraps Gemini models, with `--output-format
   json` and `mcp`/`plugin` subcommands) is **not** Gemini CLI, which is installed separately as
   `gemini` 0.57.0; the survey's gemini row only ever examined `gemini`. Whether `agy` is Google's
   Antigravity CLI is unconfirmed (its `--help` shows no context command, but a session slash
   command would not appear there). On this fleet `claude` and `copilot` are installed for sure,
   `agy` is a candidate; whether `copilot -p "/context"` or `agy -p "/context"` works headlessly
   is untested.
5. **The prototype explorer** (`~/dev-tools/agents-mgmt/context-overhead-explorer.html`, 431
   lines, no library, no generator) is driven by one hardcoded `DATA` tree at line 125: 6
   top-level categories, 645 leaves, 218,124 tokens, every node `measured:true`. It already
   renders an `estimated:true` node with an EST badge and hatch overlay; nothing uses that path.
6. **Where code lives and in what language.** Everything we build stays in `fitcode/` (fence;
   `check-fence.sh` enforces it). All 15 implementation files there are Python 3 stdlib or
   bash with a paired `test-*.sh`; `nu` and `bb` are not installed on this Mac, and the root
   `AGENTS.md` language policy governs upstream code, not the fork's folder. No ccusage crate
   exposes pricing or a tokenizer that a script could call.

## Decision

Build **one capture script for Claude Code first**, inside the fence, in the fork's own
convention, with provenance carried on every node and a table-driven seam for adding CLIs later.

- `fitcode/context-overhead.py` (Python 3 stdlib, no third-party packages). It runs the probe,
  parses the markdown in `result`, normalizes to a JSON tree, and writes JSON (default), a text
  table (`--table`), or a regenerated explorer HTML (`--html <template> <out>`) by replacing the
  JSON literal assigned to `DATA` in a copy of the prototype; the prototype itself is not edited
  and remains outside this repo.
- **Provenance is explicit and never blended.** Every node carries `provenance`
  (`"reported"` for a CLI's own introspection, `"derived"` for values tokenized from raw
  prompt material, `"estimated"` for corpus or word-count guesses) and `precision`
  (`"exact"`, `"rounded"` for `k`/`~` notation, `"bound"` for `< N`). For the existing explorer
  the script also sets `measured:true` on `reported`/`derived` nodes and `estimated:true` on
  `estimated` nodes, so the unchanged HTML renders the badges correctly. In v1 every node is
  `reported`.
- **Cold-start total = sum of category rows minus `Messages` and `Free space`.** `Messages` is
  the probe's own prompt; `Free space` is the remainder of the window. Both are kept in the
  snapshot header, not in the tree. Per-item tables do not necessarily sum to their category
  (deferred vs loaded MCP tools; System tools has no breakdown); category rows are the node
  values and item tables are children, with a warning when children exceed the parent.
- **Every snapshot records what it measured:** ISO timestamp, hostname, `agent: "claude"`,
  `claude --version`, model, working directory, config dir (default `~/.claude` or the
  `--config-dir` passed), window size, reported total, cold-start total.
- **Multi-account and multi-project are flags, not defaults.** `--config-dir <path>` sets
  `CLAUDE_CONFIG_DIR` for the probe subprocess only (never exported globally; `fitcode/README.md`
  already warns why). `--cwd <dir>` runs the probe there so project memory files are included.
- **Language:** Python 3 stdlib plus a bash test, matching every other file in `fitcode/`. The
  repo's Rust / Nushell / Babashka ladder is honored for upstream code; the fork folder's de facto
  convention is Python, and neither `nu` nor `bb` exists on the fleet.
- **Location:** `fitcode/` only. No `rust/`, `apps/`, or `docs/` changes.
- **GATE (recommended: no) — no new top-level `ccusage` command.** A `ccusage overhead`
  subcommand would live in `rust/crates/ccusage`, outside the fence, and would be a public
  surface on an upstream project that has no tokenizer and no cold-start concept. The script
  stands beside `fleet-report.sh` instead.
- **GATE (recommended: no) — no x1xhlol corpus dependency.** The corpus yields `estimated`
  numbers only, needs hand categorization per product and a tokenizer, and adds an external
  sync this tool otherwise lacks. Five CLIs already self-report; the corpus only earns its place
  if Micah wants cross-product comparison of tools not on this fleet.

### Options considered (A chosen)

| | Will it actually work? | Who maintains this? | Does it work on every agent? |
|---|---|---|---|
| **A. Claude-only capture script, table-driven for more (⭐️ chosen)** | Yes: verified this session at zero cost; parser fails loud on format drift | Micah; one script + one test + one pinned fixture per Claude version | Claude now; a second CLI is one probe row + parser |
| B. Multi-CLI framework now (5 introspecting CLIs + corpus for the rest) | 1 of 5 verified headless; 3 of 5 not installed here; corpus is guesswork | Five parsers and a corpus sync, most untestable on this fleet | Broadest on paper, mostly `estimated` in practice |
| C. No tool: document the one-liner, hand-paste into the HTML | Yes | Nothing | Claude only; no history, no repeatability, explorer stays stale |

🧪 The test that flips A toward "A plus Copilot in v1": `copilot -p "/context"` returning its
breakdown non-interactively on this Mac. Run it as the first follow-up spike.

## Data Flow

1. **Probe.** `subprocess.run(["claude", "-p", "/context", "--output-format", "json",
   "--model", "<cheapest available>"], cwd=<--cwd>, env=<inherited + optional
   CLAUDE_CONFIG_DIR>, timeout=120)`. Stdout is parsed as JSON. The run is rejected (exit 1,
   raw output saved next to the intended output) unless `type == "result"`,
   `is_error == false`, and `local_command == "context"`. `--from <raw.json>` replays a saved
   probe instead of running one (tests, MacBook captures shipped over, old versions).
2. **Parse.** Split `result` on `### ` headings. Read `**Model:**` and `**Tokens:** A / B (P%)`.
   Each table: header row gives column names; rows are `| a | b | c |`. Token cells:
   `468` → exact; `3.4k` → 3400 rounded; `~170` → 170 rounded; `< 20` → 20 bound. Any
   heading, column set, or cell the parser does not recognize is a hard failure that prints the
   offending line; the tool never emits a partial tree silently.
3. **Normalize.** Build the tree: root (agent, totals) → category nodes from the category table
   → children from the matching item table (MCP tools grouped by Server; Skills and Custom
   agents grouped by Source; Memory files flat). Attach `provenance`, `precision`, and the
   explorer-compatible `measured`/`estimated` booleans. Compute cold-start total; warn on
   child-sum overflow.
4. **Emit.** JSON to stdout or `--out`; `--table` prints category rows and top-N items;
   `--html` reads a template, asserts exactly one `DATA` assignment, replaces its literal, and
   writes the copy. Snapshots are plain files the caller names; nothing is written under the
   repo by default.

## Required Changes

- Add `fitcode/context-overhead.py` (probe, parse, normalize, emit; `--from`, `--cwd`,
  `--config-dir`, `--out`, `--table`, `--html`).
- Add `fitcode/test-context-overhead.sh` (see Validation).
- Keep `fitcode/fixtures/context-claude-2.1.275.json` (already saved this session) as the
  pinned parse fixture; add one fixture per Claude Code version whose output shape changes.
- Update `fitcode/README.md`: a "Cold-start context overhead" section with the one command,
  what `reported`/`rounded` mean, and the two files in the file list.
- Nothing outside `fitcode/`.

## Validation

`fitcode/test-context-overhead.sh` proves, offline and without spending tokens:

- parsing the pinned fixture yields model `claude-haiku-4-5-20251001`, window 200000, reported
  total 35700, 7 cold-start categories (Messages and Free space excluded), 53 MCP tool rows, 2
  custom agents, 3 memory files, 117 skills;
- token notation: `468` exact, `3.4k` → 3400 rounded, `~170` → 170 rounded, `< 20` → 20 bound;
- **deliberate breakage:** a fixture with `### Skills` renamed, a fixture with an extra column,
  and a fixture whose `local_command` is not `context` each exit 1 with the offending line
  printed and no JSON on stdout (the substrate rule: a verification tool ships with a test that
  fails when the tool breaks);
- `--html` output differs from the template only inside the `DATA` literal and still contains
  exactly one `<script`;
- `--config-dir` does not leak: the caller's environment has no `CLAUDE_CONFIG_DIR` after the
  run.

Live smoke, once, on the mini: run the probe, compare the reported total with an interactive
`/context` in the same directory, and note both in the commit message.

## Documentation Impact

- `fitcode/README.md`: new section and file-list entries.
- `fitcode/specs/2026-09-16-context-overhead-explorer-ideation.md`: status line pointing here
  (done this session).
- The explorer HTML in `agents-mgmt` gets no edit; the script produces a regenerated copy.

## Out of Scope

- Other CLIs. **Next spike:** `copilot -p "/context"` headless; if it works, Copilot is the
  second probe row. Antigravity is a candidate only if a capture path is found (see the `agy`
  note above). Kilo and Hermes are not installed on the fleet; Cursor is unresolved.
- `derived` numbers from the `prompt_snapshot` attachment (exact per-tool counts). Documented
  as the v2 path; needs a tokenizer decision.
- A per-session "first-turn input tokens" metric from existing logs (a different number: it
  includes the user's first message and cache state).
- A spend-sheet tab or fleet aggregation of snapshots.
- The x1xhlol corpus and any upstream `ccusage` command (both GATEs above).

## Compatibility

- Depends on undocumented Claude Code behavior (`/context` in `-p` mode, the `result` markdown
  layout). Mitigations: the version is recorded in every snapshot, the parser fails loud, one
  fixture is pinned per version, and the README says to re-run the test after a Claude Code
  upgrade.
- The JSON is a superset of the explorer's `DATA` schema (extra fields ignored by the HTML).
- No change to `ccusage` itself, so upstream pulls keep passing `check-fence.sh`.

## Watchlist (not blocking)

- Cursor CLI vs IDE breakdown tray; Hermes category list; amp, codebuff, zcode unverified.
- `fitcode/README.md` labels the fleet row "agy (gemini)"; `agy` is not Gemini CLI. Which ccusage
  adapter (if any) counts agy's sessions was measured by an earlier session and is not re-checked
  here; fix the label only after re-checking.
- `/context` totals drift with model choice (`--model` changes the window and the report).
- Recon reports for this design live only in the session scratchpad; the facts that matter are
  restated above and in the Scribe ledger for session 2026-09-17-79bd7d64.
