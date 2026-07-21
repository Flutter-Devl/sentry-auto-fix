#!/usr/bin/env python3
"""Optional CodeGuardian AI validate/analyze hook for Flutter worktrees."""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from pathlib import Path


def run_codeguardian(
    *,
    worktree: Path,
    cli: str,
    mode: str = "validate",
    timeout: int = 600,
) -> tuple[bool, str]:
    """
    Run CodeGuardian CLI against the fix worktree.

    cli examples:
      - /usr/local/bin/codeguardian
      - dart run /path/to/packages/codeguardian_cli/bin/codeguardian.dart
    """
    if not cli.strip():
        return False, "CODEGUARDIAN_CLI is empty"

    # Split so "dart run path/to/bin.dart" works
    parts = shlex.split(cli)
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
    tail = "\n".join(out.splitlines()[-40:])
    # CodeGuardian: 0 pass, 1 gate failure, 2 tool error
    ok = proc.returncode == 0
    return ok, f"exit={proc.returncode}\n{tail}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run CodeGuardian on a worktree")
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--cli", default=os.environ.get("CODEGUARDIAN_CLI", ""))
    parser.add_argument("--mode", default=os.environ.get("CODEGUARDIAN_MODE", "validate"))
    parser.add_argument("--timeout", type=int, default=int(os.environ.get("CODEGUARDIAN_TIMEOUT", "600")))
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
