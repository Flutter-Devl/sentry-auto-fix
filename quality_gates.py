#!/usr/bin/env python3
"""Post-agent quality gates: tests, confidence, banned diff patterns."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

RESULT_FIELDS = (
    "ISSUE_SHORT_ID",
    "ISSUE_TIER",
    "FIX_CONFIDENCE",
    "FIX_STRATEGY",
    "TEST_COMMAND",
    "TEST_RESULT",
    "BRANCH_NAME",
)


def load_env_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        data[key.strip()] = value.strip()
    return data


def parse_pr_body_tests(pr_body_path: Path) -> tuple[str, str]:
    if not pr_body_path.exists():
        return "", ""
    text = pr_body_path.read_text(encoding="utf-8", errors="replace")
    command = ""
    result = ""

    cmd_match = re.search(
        r"(?:\*\*Command(?: run)?:\*\*|Command:)\s*`([^`]+)`", text, re.I
    )
    if cmd_match:
        command = cmd_match.group(1).strip()

    if re.search(r"\bPASSED\b|✅\s*PASSED", text, re.I):
        result = "PASSED"
    elif re.search(r"\bFAILED\b|❌\s*FAILED", text, re.I):
        result = "FAILED"

    return command, result


def git_diff_text(worktree: Path) -> str:
    if not worktree.exists():
        return ""
    for args in (
        ["git", "-C", str(worktree), "diff", "HEAD~1", "HEAD"],
        ["git", "-C", str(worktree), "diff", "HEAD"],
    ):
        proc = subprocess.run(args, capture_output=True, text=True)
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout
    return ""


def diff_has_before_send_filter(diff: str) -> bool:
    if not diff:
        return False
    patterns = (
        r"beforeSend",
        r"_sentryBeforeSend",
        r"options\.beforeSend",
    )
    added = "\n".join(
        line[1:] for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++")
    )
    return any(re.search(p, added) for p in patterns)


def run_test_command(worktree: Path, command: str, timeout: int) -> tuple[bool, str]:
    proc = subprocess.run(
        command,
        shell=True,
        cwd=worktree,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    output = (proc.stdout or "") + (proc.stderr or "")
    tail = "\n".join(output.strip().splitlines()[-20:])
    return proc.returncode == 0, tail


def default_test_command(profile: str, pr_body_path: Path, worktree: Path) -> str:
    cmd, _ = parse_pr_body_tests(pr_body_path)
    if cmd:
        return cmd

    if profile == "laravel":
        return "php artisan test"
    if profile in ("flutter", "mobile", "dart"):
        test_files = sorted(worktree.glob("test/**/*_test.dart"))
        if not test_files:
            test_files = sorted(worktree.glob("test/**/*.dart"))
        if test_files:
            rel = [str(path.relative_to(worktree)) for path in test_files[-3:]]
            return "flutter test " + " ".join(rel)
        return "flutter test"
    return ""


def verify(
    *,
    state_dir: Path,
    worktree: Path,
    profile: str,
    require_tests_tier12: bool,
    min_confidence: str,
    test_gate_enabled: bool,
    test_timeout: int,
) -> int:
    result_path = state_dir / "run-result.env"
    pr_body_path = state_dir / "pr-body.md"
    results = load_env_file(result_path)

    if results.get("NO_ACTION") == "true":
        print("quality-gates: skip (NO_ACTION)")
        return 0

    branch = results.get("BRANCH_NAME", "")
    if not branch:
        print("quality-gates: skip (no branch pushed)")
        return 0

    tier = (results.get("ISSUE_TIER") or "").lower()
    confidence = (results.get("FIX_CONFIDENCE") or "medium").lower()
    strategy = results.get("FIX_STRATEGY", "")
    test_command = results.get("TEST_COMMAND", "")
    test_result = (results.get("TEST_RESULT") or "").upper()

    min_rank = {"low": 0, "medium": 1, "high": 2}.get(min_confidence.lower(), 1)
    conf_rank = {"low": 0, "medium": 1, "high": 2}.get(confidence, 1)

    print(f"quality-gates: tier={tier or 'unknown'} confidence={confidence} strategy={strategy or 'n/a'}")

    if conf_rank < min_rank:
        print(f"quality-gates: FAILED — FIX_CONFIDENCE={confidence} below minimum {min_confidence}")
        return 1

    diff = git_diff_text(worktree)
    if tier in ("tier1", "tier2") and diff_has_before_send_filter(diff):
        print("quality-gates: FAILED — beforeSend / Sentry filter change banned for tier1/tier2")
        return 1

    if not test_gate_enabled:
        print("quality-gates: test gate disabled")
        return 0

    require_tests = require_tests_tier12 and tier in ("tier1", "tier2")
    if not require_tests:
        print("quality-gates: tests not required for this tier")
        return 0

    if not test_command:
        test_command, body_result = parse_pr_body_tests(pr_body_path)
        if body_result:
            test_result = body_result

    if not test_command:
        test_command = default_test_command(profile, pr_body_path, worktree)

    if not test_command:
        print("quality-gates: FAILED — no TEST_COMMAND provided for tier1/tier2")
        return 1

    if test_result == "PASSED":
        print(f"quality-gates: agent reported tests PASSED ({test_command})")
        return 0

    print(f"quality-gates: running tests: {test_command}")
    ok, tail = run_test_command(worktree, test_command, test_timeout)
    print(tail)
    if ok:
        print("quality-gates: PASSED")
        return 0

    print("quality-gates: FAILED — tests did not pass")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Post-agent quality gates")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--profile", default="flutter")
    parser.add_argument("--require-tests-tier12", default="true")
    parser.add_argument("--min-confidence", default="medium")
    parser.add_argument("--test-gate-enabled", default="true")
    parser.add_argument("--test-timeout", type=int, default=600)
    args = parser.parse_args()

    return verify(
        state_dir=Path(args.state_dir),
        worktree=Path(args.worktree),
        profile=args.profile.lower(),
        require_tests_tier12=args.require_tests_tier12.lower() in ("1", "true", "yes"),
        min_confidence=args.min_confidence,
        test_gate_enabled=args.test_gate_enabled.lower() in ("1", "true", "yes"),
        test_timeout=args.test_timeout,
    )


if __name__ == "__main__":
    raise SystemExit(main())
