#!/usr/bin/env python3
"""Optional CodeGuardian AI validate/analyze hook for Flutter worktrees."""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path


def _extract_json_payload(text: str) -> str | None:
    """Return the largest parseable JSON object/array substring, if any."""
    text = text.strip()
    if not text:
        return None
    for open_ch, close_ch in (("{", "}"), ("[", "]")):
        start = text.find(open_ch)
        end = text.rfind(close_ch)
        if start < 0 or end <= start:
            continue
        candidate = text[start : end + 1]
        try:
            json.loads(candidate)
            return candidate
        except json.JSONDecodeError:
            continue
    return None


def run_codeguardian(
    *,
    worktree: Path,
    cli: str,
    mode: str = "validate",
    timeout: int = 600,
) -> tuple[bool, str]:
    """
    Run CodeGuardian CLI against the fix worktree.

    Returns (ok, detail). Detail prefers full JSON when present so Slack can
    summarize findings; falls back to a short text tail.
    """
    if not cli.strip():
        return False, "CODEGUARDIAN_CLI is empty"

    parts = shlex.split(cli)
    if len(parts) == 1 and not Path(parts[0]).is_absolute():
        resolved = Path(parts[0]).expanduser().resolve()
        if resolved.exists():
            parts = [str(resolved)]
    cmd = [*parts, mode, "-p", str(worktree)]

    try:
        proc = subprocess.run(
            cmd,
            cwd=worktree,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        return False, f"CodeGuardian CLI not found: {exc}"
    except subprocess.TimeoutExpired:
        return False, f"CodeGuardian timed out after {timeout}s"

    out = ((proc.stdout or "") + (proc.stderr or "")).strip()
    ok = proc.returncode == 0
    payload = _extract_json_payload(out)
    if payload:
        if len(payload) > 200_000:
            payload = payload[:200_000]
        return ok, f"exit={proc.returncode}\n{payload}"

    tail = "\n".join(out.splitlines()[-40:])
    return ok, f"exit={proc.returncode}\n{tail}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run CodeGuardian on a worktree")
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--cli", default=os.environ.get("CODEGUARDIAN_CLI", ""))
    parser.add_argument("--mode", default=os.environ.get("CODEGUARDIAN_MODE", "validate"))
    parser.add_argument(
        "--timeout", type=int, default=int(os.environ.get("CODEGUARDIAN_TIMEOUT", "600"))
    )
    args = parser.parse_args()

    if not args.cli:
        print("codeguardian: skipped (CODEGUARDIAN_CLI not set)")
        return 0

    ok, detail = run_codeguardian(
        worktree=Path(args.worktree),
        cli=args.cli,
        mode=args.mode,
        timeout=args.timeout,
    )
    print(detail)
    if ok:
        print("codeguardian: PASSED")
        return 0
    print("codeguardian: FAILED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
