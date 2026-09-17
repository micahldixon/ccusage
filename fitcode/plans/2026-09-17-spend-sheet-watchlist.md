# Watchlist — fleet spend sheet (2026-09-17)

Not blocking use of the Dashboard. File these before calling the reporting surface done.

- [ ] **dsh / DeepSeek Harness reader.** Sessions in `~/.dsh/sessions` (`*.jsonl.zstd`) carry `inputTokens` / `outputTokens` / `cacheReadTokens`. Same fitcode-converter pattern as jcode. Not in ccusage today.
- [ ] **Still no bill:** ChatGPT Work mode, agy (no usage transcripts), forge-agent (no data). super.engineering is a host, not a bill — do not double-count.
- [ ] **Richer Master columns (optional):** tokens vs cache, Cursor included vs on-demand, IDE vs headless, list price vs charged, session id.
- [ ] **Push** `0ca8d03f` and the dashboard commit so the MacBook can `--fleet` on the same SHA.
- [ ] **Upstream pull** if `check-fence.sh` exits 2 (original repo moved again). Always pull before new fitcode work.
- [ ] **Keep/cut calls** on Dashboard are a heuristic (tiny all-time + tiny this month → cut candidate). Not proof you should cancel.

Grokbot was never a separate fleet line. It is a Cursor model (`grok-bot-default`). GitHub Bugbot is Cursor extra. The `grok` Dashboard row is the Grok CLI.

Sheet: [Fitcode agent spend history](https://docs.google.com/spreadsheets/d/1on7v_bYdEmb2UXIuWpDuYTLZ-JPFOojJrqmvlOtnK6Q/edit) — Dashboard + Master + ChartData.

Separate, ready when you want a fresh session: `fitcode/specs/2026-09-16-context-overhead-explorer-ideation_PROMPT.md` (brainstorm only, no code).
