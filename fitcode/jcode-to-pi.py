#!/usr/bin/env python3
"""Convert jcode session usage records into pi-adapter JSONL.

Why: jcode has no ccusage reader of its own (see fitcode/plans/2026-09-17-
jcode-reader-and-fleet-total.md, Phase 0). Rather than write a second price
list, this script rewrites jcode's per-session usage into the line shape
`rust/adapters/pi` already reads, in a private temp folder; the wrapper
(fleet-report.sh) then passes that folder to ccusage as the pi named store
"jcode" (a temporary --config), so its rows show up as agent "jcode". The
folder is the store's only path, so this never reads or touches a real
`~/.pi` directory, and this script is READ-ONLY on `~/.jcode`.

Usage:
    jcode-to-pi.py --out DIR [--sessions DIR]

Default --sessions: `$JCODE_HOME/sessions` if JCODE_HOME is set in the
environment, else `~/.jcode/sessions`. A missing sessions directory is a
normal state (a Mac with no jcode installed) -- nothing is written and the
script exits 0.

Session file shapes (confirmed against the real ~/.jcode/sessions corpus,
917 sessions / 9,329 usage records, while building this script):
  - `<stem>.json` -- one JSON object per session: session-level `model` /
    `provider_key`, and a `messages` array. An assistant message with a
    `token_usage` object counts; everything else (user messages, assistant
    messages with no token_usage) is ignored.
  - `<stem>.bak` -- an older snapshot of the same session. Only read when
    `<stem>.json` is missing or fails to parse -- never as a second source of
    records when `<stem>.json` is already good, and never as a stand-in for a
    DIFFERENT stem: filenames like
    `<stem>.json.pre-wipe-<epoch>.bak` (a real pre-wipe backup shape found on
    the mini corpus) end in `.bak` but must never be read as `<stem>`'s own
    backup -- see `_is_real_bak_stem`.
  - `<stem>.journal.jsonl` -- messages appended after the last `.json`/`.bak`
    snapshot, one JSON object per line: `{"meta": {...}, "append_messages":
    [...]}`. `meta.model` / `meta.provider_key` apply to that line's messages
    when present (non-null/non-empty); otherwise the session-level model/
    provider_key (from `.json`/`.bak`) is used.
  - Anything else under sessions/ (crash-write temp files like
    `<stem>.tmp.<pid>.<n>`, the sqlite session index, etc.) is ignored: this
    script only ever opens files it reached via the three globs above.

Dedup: by message `id`, per session, across its `.json`/`.bak` base and its
`.journal.jsonl` (a message appended to the journal and later folded into the
`.json` snapshot would otherwise be double-counted). Measured directly
against the real mini corpus (see Phase 2 of fitcode/plans/2026-09-17-jcode-
reader-and-fleet-total.md): zero usage records are copied into a *different*
session under a new message id, so no cross-session dedup is implemented.

Two correctness rules, both required and both verified against the real mini
corpus before shipping (see the jcode-impl report):
  1. Timestamps: `rust/crates/ccusage-core`'s hand-rolled RFC3339 parser only
     accepts 0 or exactly 3 fractional digits. jcode emits 6-digit
     microseconds; truncating to 3 is mandatory or the parser silently drops
     the whole line (no error, just missing from every report).
  2. Input tokens: OpenAI-family providers (`provider_key` starting with
     "openai", and defensively "grok-build") report `input_tokens` INCLUDING
     `cache_read_input_tokens`; Claude-family providers do not. Only
     cache_read is subtracted (never cache_creation) -- confirmed against
     5,212+ real OpenAI-family records where cache_read never exceeds input,
     and 4,000+ real Claude-family records where it almost always does.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

CACHE_INCLUSIVE_EXACT = {"grok-build"}
_FRACTION_RE = re.compile(r"\.(\d+)(Z|[+-]\d{2}:\d{2})$")


def is_cache_inclusive_provider(provider_key):
    """OpenAI-family (any provider_key starting with 'openai') and,
    defensively, grok-build: input_tokens includes cache_read_input_tokens."""
    if not provider_key:
        return False
    if provider_key in CACHE_INCLUSIVE_EXACT:
        return True
    return provider_key.startswith("openai")


def truncate_timestamp(ts):
    """Truncate a jcode ISO-8601 timestamp's fractional seconds to exactly 3
    digits (milliseconds), the only fractional width ccusage-core's
    hand-rolled parse_ts_timestamp accepts (besides none at all). A timestamp
    with no fractional part, or an unexpected shape, passes through
    unchanged."""
    if not isinstance(ts, str):
        return ts
    m = _FRACTION_RE.search(ts)
    if not m:
        return ts
    frac, suffix = m.groups()
    frac3 = (frac + "000")[:3]
    return ts[: m.start()] + "." + frac3 + suffix


def pi_input_tokens(provider_key, tu):
    """pi's usage.input, per the input-token rule (module docstring, rule 2).
    Only cache_read_input_tokens is subtracted; cache_creation_input_tokens
    is never subtracted (it is mapped separately to cacheWrite)."""
    inp = tu.get("input_tokens") or 0
    if is_cache_inclusive_provider(provider_key):
        cr = tu.get("cache_read_input_tokens") or 0
        return max(0, inp - cr)
    return inp


def _is_real_bak_stem(stem):
    """Guards against jcode's own pre-wipe backup naming,
    `<stem>.json.pre-wipe-<epoch>.bak` / `<stem>.journal.jsonl.pre-wipe-
    <epoch>.bak` (found on the real mini corpus): both end in `.bak`, but
    stripping just the trailing `.bak` yields a fake "stem" that still
    contains `.json`/`.jsonl` in it. A real session stem never does."""
    return ".json" not in stem and ".jsonl" not in stem


def _collect_stems(sessions_dir):
    stems = set()
    for p in sessions_dir.glob("*.json"):
        stems.add(p.stem)
    for p in sessions_dir.glob("*.journal.jsonl"):
        name = p.name
        stems.add(name[: -len(".journal.jsonl")])
    for p in sessions_dir.glob("*.bak"):
        stem = p.name[: -len(".bak")]
        if _is_real_bak_stem(stem):
            stems.add(stem)
    return stems


def _load_json_file(path):
    with open(path, "r") as f:
        return json.load(f)


def _load_session_base(stem, sessions_dir, unreadable):
    """Returns the parsed session dict (session-level model/provider_key +
    messages), preferring `<stem>.json`; falls back to `<stem>.bak` only when
    the `.json` is missing or fails to parse. Increments `unreadable[0]` once
    per file that existed but could not be parsed."""
    json_path = sessions_dir / f"{stem}.json"
    if json_path.exists():
        try:
            return _load_json_file(json_path)
        except Exception:
            unreadable[0] += 1
    bak_path = sessions_dir / f"{stem}.bak"
    if bak_path.exists():
        try:
            return _load_json_file(bak_path)
        except Exception:
            unreadable[0] += 1
    return None


def _records_from_messages(messages, model, provider_key):
    for m in messages or []:
        if m.get("role") != "assistant":
            continue
        tu = m.get("token_usage")
        if not tu:
            continue
        mid = m.get("id")
        if mid is None:
            continue
        yield mid, {
            "model": model,
            "provider_key": provider_key,
            "timestamp": m.get("timestamp"),
            "token_usage": tu,
        }


def _records_from_journal(journal_path, session_model, session_provider_key, unreadable):
    try:
        text = journal_path.read_text()
    except Exception:
        unreadable[0] += 1
        return
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            # A malformed individual journal line is skipped on its own; the
            # rest of the (mostly fine) file is still read.
            continue
        meta = d.get("meta") or {}
        line_model = meta.get("model") or session_model
        line_provider_key = meta.get("provider_key") or session_provider_key
        yield from _records_from_messages(d.get("append_messages"), line_model, line_provider_key)


def _build_pi_line(rec):
    tu = rec["token_usage"]
    pi_in = pi_input_tokens(rec["provider_key"], tu)
    pi_out = tu.get("output_tokens") or 0
    cache_read = tu.get("cache_read_input_tokens") or 0
    cache_write = tu.get("cache_creation_input_tokens") or 0
    if pi_in == 0 and pi_out == 0 and cache_read == 0 and cache_write == 0:
        return None
    total = pi_in + pi_out + cache_read + cache_write
    return {
        "type": "message",
        "timestamp": truncate_timestamp(rec.get("timestamp")),
        "message": {
            "role": "assistant",
            "model": rec.get("model"),
            "usage": {
                "input": pi_in,
                "output": pi_out,
                "cacheRead": cache_read,
                "cacheWrite": cache_write,
                "totalTokens": total,
            },
        },
    }


def convert_session(stem, sessions_dir, unreadable):
    """Returns a list of JSON-encoded pi-format lines for one session stem,
    deduped by message id across its .json/.bak base and its
    .journal.jsonl."""
    session_data = _load_session_base(stem, sessions_dir, unreadable)
    session_model = session_data.get("model") if session_data else None
    session_provider_key = session_data.get("provider_key") if session_data else None

    seen_ids = set()
    lines = []

    if session_data:
        for mid, rec in _records_from_messages(
            session_data.get("messages"), session_model, session_provider_key
        ):
            if mid in seen_ids:
                continue
            seen_ids.add(mid)
            line = _build_pi_line(rec)
            if line is not None:
                lines.append(json.dumps(line))

    journal_path = sessions_dir / f"{stem}.journal.jsonl"
    if journal_path.exists():
        for mid, rec in _records_from_journal(
            journal_path, session_model, session_provider_key, unreadable
        ):
            if mid in seen_ids:
                continue
            seen_ids.add(mid)
            line = _build_pi_line(rec)
            if line is not None:
                lines.append(json.dumps(line))

    return lines


def convert_all(sessions_dir, out_dir):
    """Returns (n_sessions_written, total_lines, unreadable_count)."""
    unreadable = [0]
    stems = _collect_stems(sessions_dir)
    n_written = 0
    total_lines = 0
    for stem in sorted(stems):
        lines = convert_session(stem, sessions_dir, unreadable)
        if lines:
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path = out_dir / f"{stem}.jsonl"
            out_path.write_text("\n".join(lines) + "\n")
            n_written += 1
            total_lines += len(lines)
    return n_written, total_lines, unreadable[0]


def default_sessions_dir():
    jcode_home = os.environ.get("JCODE_HOME")
    base = Path(jcode_home) if jcode_home else Path.home() / ".jcode"
    return base / "sessions"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, help="output directory for pi-format JSONL")
    ap.add_argument(
        "--sessions",
        default=None,
        help="jcode sessions directory (default: $JCODE_HOME/sessions or ~/.jcode/sessions)",
    )
    args = ap.parse_args(argv)

    sessions_dir = Path(args.sessions) if args.sessions else default_sessions_dir()
    out_dir = Path(args.out)

    if not sessions_dir.is_dir():
        # A Mac with no jcode installed is normal, not an error.
        return 0

    n_written, total_lines, unreadable = convert_all(sessions_dir, out_dir)

    if unreadable > 0:
        print(
            f"jcode-to-pi: skipped {unreadable} unreadable jcode session file(s)",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
