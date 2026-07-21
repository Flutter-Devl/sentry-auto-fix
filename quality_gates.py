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


def append_result_env(state_dir: Path, **fields: str) -> None:
    result_path = state_dir / "run-result.env"
    lines = []
    for key, value in fields.items():
        if value is None:
            continue
        # Single-line env values; collapse newlines for shell parsers.
        safe = " ".join(str(value).splitlines()).strip()
        lines.append(f"{key}={safe}")
    if not lines:
        return
    with result_path.open("a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def write_detail_file(state_dir: Path, name: str, text: str) -> None:
    path = state_dir / name
    path.write_text((text or "").strip() + "\n", encoding="utf-8")


def run_codeguardian_gate(
    *,
    state_dir: Path,
    worktree: Path,
    profile: str,
    enabled: bool,
    cli: str,
    mode: str,
    timeout: int,
    fail_blocks_pr: bool,
) -> int:
    """Optional CodeGuardian validate after unit tests (Flutter only)."""
    if not enabled:
        print("quality-gates: CodeGuardian disabled")
        append_result_env(state_dir, CODEGUARDIAN_STATUS="disabled")
        return 0
    if profile not in ("flutter", "mobile", "dart"):
        print("quality-gates: CodeGuardian skipped (Flutter profile only)")
        append_result_env(state_dir, CODEGUARDIAN_STATUS="skipped")
        return 0
    if not cli.strip():
        print("quality-gates: CodeGuardian enabled but CODEGUARDIAN_CLI empty — skip")
        append_result_env(state_dir, CODEGUARDIAN_STATUS="skipped")
        return 0

    from codeguardian_gate import run_codeguardian

    print(f"quality-gates: running CodeGuardian ({mode})...")
    ok, detail = run_codeguardian(
        worktree=worktree, cli=cli, mode=mode, timeout=timeout
    )
    print(detail)
    write_detail_file(state_dir, "codeguardian-detail.txt", detail)
    if ok:
        print("quality-gates: CodeGuardian PASSED")
        append_result_env(state_dir, CODEGUARDIAN_STATUS="passed", CODEGUARDIAN_MODE=mode)
        return 0
    append_result_env(
        state_dir,
        CODEGUARDIAN_STATUS="failed",
        CODEGUARDIAN_MODE=mode,
        QUALITY_GATE_REASON="codeguardian",
    )
    if fail_blocks_pr:
        print("quality-gates: FAILED — CodeGuardian gate blocked PR")
        return 1
    print("quality-gates: CodeGuardian failed but CODEGUARDIAN_FAIL_BLOCKS_PR=false — continuing")
    return 0


def verify(
    *,
    state_dir: Path,
    worktree: Path,
    profile: str,
    require_tests_tier12: bool,
    min_confidence: str,
    test_gate_enabled: bool,
    test_timeout: int,
    codeguardian_enabled: bool = False,
    codeguardian_cli: str = "",
    codeguardian_mode: str = "validate",
    codeguardian_timeout: int = 600,
    codeguardian_fail_blocks_pr: bool = True,
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

    def fail(reason: str, message: str) -> int:
        print(message)
        append_result_env(state_dir, QUALITY_GATE_REASON=reason)
        return 1

    if conf_rank < min_rank:
        return fail(
            "confidence",
            f"quality-gates: FAILED — FIX_CONFIDENCE={confidence} below minimum {min_confidence}",
        )

    diff = git_diff_text(worktree)
    if tier in ("tier1", "tier2") and diff_has_before_send_filter(diff):
        return fail(
            "beforeSend",
            "quality-gates: FAILED — beforeSend / Sentry filter change banned for tier1/tier2",
        )

    cg_kwargs = dict(
        state_dir=state_dir,
        worktree=worktree,
        profile=profile,
        enabled=codeguardian_enabled,
        cli=codeguardian_cli,
        mode=codeguardian_mode,
        timeout=codeguardian_timeout,
        fail_blocks_pr=codeguardian_fail_blocks_pr,
    )

    if not test_gate_enabled:
        print("quality-gates: test gate disabled")
        return run_codeguardian_gate(**cg_kwargs)

    require_tests = require_tests_tier12 and tier in ("tier1", "tier2")
    if not require_tests:
        print("quality-gates: tests not required for this tier")
        return run_codeguardian_gate(**cg_kwargs)

    if not test_command:
        test_command, body_result = parse_pr_body_tests(pr_body_path)
        if body_result:
            test_result = body_result

    if not test_command:
        test_command = default_test_command(profile, pr_body_path, worktree)

    if not test_command:
        return fail(
            "tests",
            "quality-gates: FAILED — no TEST_COMMAND provided for tier1/tier2",
        )

    if test_result == "PASSED":
        print(f"quality-gates: agent reported tests PASSED ({test_command})")
    else:
        print(f"quality-gates: running tests: {test_command}")
        ok, tail = run_test_command(worktree, test_command, test_timeout)
        print(tail)
        write_detail_file(state_dir, "test-gate-detail.txt", tail)
        if not ok:
            return fail("tests", "quality-gates: FAILED — tests did not pass")
        print("quality-gates: tests PASSED")

    return run_codeguardian_gate(**cg_kwargs)


def main() -> int:
    parser = argparse.ArgumentParser(description="Post-agent quality gates")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--profile", default="flutter")
    parser.add_argument("--require-tests-tier12", default="true")
    parser.add_argument("--min-confidence", default="medium")
    parser.add_argument("--test-gate-enabled", default="true")
    parser.add_argument("--test-timeout", type=int, default=600)
    parser.add_argument("--codeguardian-enabled", default="false")
    parser.add_argument("--codeguardian-cli", default="")
    parser.add_argument("--codeguardian-mode", default="validate")
    parser.add_argument("--codeguardian-timeout", type=int, default=600)
    parser.add_argument("--codeguardian-fail-blocks-pr", default="true")
    args = parser.parse_args()

    return verify(
        state_dir=Path(args.state_dir),
        worktree=Path(args.worktree),
        profile=args.profile.lower(),
        require_tests_tier12=args.require_tests_tier12.lower() in ("1", "true", "yes"),
        min_confidence=args.min_confidence,
        test_gate_enabled=args.test_gate_enabled.lower() in ("1", "true", "yes"),
        test_timeout=args.test_timeout,
        codeguardian_enabled=args.codeguardian_enabled.lower() in ("1", "true", "yes"),
        codeguardian_cli=args.codeguardian_cli,
        codeguardian_mode=args.codeguardian_mode,
        codeguardian_timeout=args.codeguardian_timeout,
        codeguardian_fail_blocks_pr=args.codeguardian_fail_blocks_pr.lower()
        in ("1", "true", "yes"),
    )


if __name__ == "__main__":
    raise SystemExit(main())
