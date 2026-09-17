#!/usr/bin/env python3
"""Convert DeepSeek Harness (dsh) session usage into pi-adapter JSONL.

dsh has no ccusage reader. This rewrites assistant/message usage into the
line shape rust/adapters/pi already prices. fleet-report.sh passes the
folder as the pi named store "dsh". READ-ONLY on ~/.dsh.

Usage:
    dsh-to-pi.py --out DIR [--sessions DIR]

Default --sessions: $DSH_HOME/sessions or ~/.dsh/sessions. A missing
directory is normal and exits 0.

Per session folder, one file is read, first match:
session.v3.jsonl(.zstd), session.v2.jsonl(.zstd), session.jsonl(.zstd).
Only `assistant/message` records with a usage object are counted — not
`assistant/chunk` copies of the same usage. Timestamps are milliseconds
and are written with exactly 3 fractional digits so ccusage keeps them.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

CANDIDATES = (
    "session.v3.jsonl.zstd",
    "session.v3.jsonl",
    "session.v2.jsonl.zstd",
    "session.v2.jsonl",
    "session.jsonl.zstd",
    "session.jsonl",
)


def die(msg: str, code: int = 2) -> None:
    print(f"dsh-to-pi: {msg}", file=sys.stderr)
    raise SystemExit(code)


def iso_ms(ms) -> str:
    x = float(ms) / 1000.0 if float(ms) > 1e12 else float(ms)
    dt = datetime.fromtimestamp(x, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(dt.microsecond / 1000):03d}Z"


def read_lines(path: Path) -> list[str]:
    if path.name.endswith(".zstd"):
        try:
            proc = subprocess.run(
                ["zstd", "-dc", str(path)],
                check=True,
                capture_output=True,
                timeout=60,
            )
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
            raise OSError(str(e)) from e
        return proc.stdout.decode("utf-8", "replace").splitlines()
    return path.read_text(encoding="utf-8").splitlines()


def pick_session_file(folder: Path) -> Path | None:
    for name in CANDIDATES:
        p = folder / name
        if p.is_file():
            return p
    return None


def pi_line(obj: dict) -> dict | None:
    if obj.get("type") != "assistant/message":
        return None
    data = obj.get("data") or {}
    usage = data.get("usage") or {}
    if not isinstance(usage, dict):
        return None
    inp = int(usage.get("inputTokens") or 0)
    out = int(usage.get("outputTokens") or 0)
    cache_read = int(usage.get("cacheReadTokens") or 0)
    cache_write = int(usage.get("cacheWriteTokens") or usage.get("cacheCreationTokens") or 0)
    if inp == 0 and out == 0 and cache_read == 0 and cache_write == 0:
        return None
    msg = data.get("message") or {}
    source = msg.get("source") or {}
    model = source.get("model") or msg.get("model")
    ts = obj.get("time")
    if ts is None:
        return None
    return {
        "type": "message",
        "timestamp": iso_ms(ts),
        "message": {
            "role": "assistant",
            "model": model,
            "usage": {
                "input": inp,
                "output": out,
                "cacheRead": cache_read,
                "cacheWrite": cache_write,
                "totalTokens": inp + out + cache_read + cache_write,
            },
        },
    }


def convert_folder(folder: Path, unreadable: list) -> list[str]:
    path = pick_session_file(folder)
    if path is None:
        return []
    try:
        raw_lines = read_lines(path)
    except OSError:
        unreadable[0] += 1
        return []
    out = []
    for line in raw_lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        built = pi_line(obj)
        if built is not None:
            out.append(json.dumps(built))
    return out


def convert_all(sessions_dir: Path, out_dir: Path) -> tuple[int, int, int]:
    unreadable = [0]
    n_written = 0
    total_lines = 0
    for dirpath, _dirnames, filenames in os.walk(sessions_dir):
        if not any(f.startswith("session") and "jsonl" in f for f in filenames):
            continue
        folder = Path(dirpath)
        lines = convert_folder(folder, unreadable)
        if not lines:
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        name = folder.name.replace("/", "_") + ".jsonl"
        (out_dir / name).write_text("\n".join(lines) + "\n")
        n_written += 1
        total_lines += len(lines)
    return n_written, total_lines, unreadable[0]


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--sessions", default=None)
    args = ap.parse_args(argv)
    if args.sessions:
        sessions_dir = Path(args.sessions)
    else:
        home = os.environ.get("DSH_HOME")
        sessions_dir = Path(home) / "sessions" if home else Path.home() / ".dsh" / "sessions"
    if not sessions_dir.is_dir():
        return 0
    n, _lines, unreadable = convert_all(sessions_dir, Path(args.out))
    if unreadable:
        print(f"dsh-to-pi: skipped {unreadable} unreadable dsh session file(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
