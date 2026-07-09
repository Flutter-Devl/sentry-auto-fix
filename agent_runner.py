"""Invoke Cursor Agent CLI in headless mode."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


def build_fix_prompt(
    *,
    issue_short_id: str,
    issue_title: str,
    issue_url: str,
    issue_id: str,
    stack_hint: str,
    base_branch: str,
    branch_name: str,
    profile: str = "flutter",
) -> str:
    """Build a Cursor Agent fix prompt tailored to the active project profile."""
    if profile == "laravel":
        project_label = "Laravel API"
        pattern_hint = "Match Laravel/PHP patterns (Eloquent, jobs, middleware, form requests, try/catch, null-safe operators)."
        code_path = "app/"
        test_cmd = "php artisan test"
    else:
        project_label = "Flutter mobile app"
        pattern_hint = "Match Flutter/Dart patterns (Riverpod, feature folders, async guards, mounted checks, existing SDK usage)."
        code_path = "lib/"
        test_cmd = "flutter test"

    return f"""You are fixing a production error from Sentry for the {project_label}.

## Sentry issue
- ID: {issue_short_id} (internal id: {issue_id})
- Title: {issue_title}
- URL: {issue_url}

## Stack / context hint
{stack_hint}

## Instructions
1. Use the **Sentry MCP** tools to fetch full issue details, latest event, and stack trace from the URL above.
2. Locate the root cause in this repository and implement a **minimal, correct fix**.
3. {pattern_hint}
4. Only edit application code under {code_path} — do not touch vendor/third-party files.
5. Do **not** commit secrets, tokens, or .env files.
6. Run targeted tests — **required** for tier1/tier2; include command + PASSED in pr-body.md
7. Stage and commit on the current branch with message:
   `fix(sentry): {issue_short_id} {issue_title[:72]}`

## Git context
- Base branch was: {base_branch}
- Current branch: {branch_name}
- Only commit if you made code changes.

When done, reply with a short summary: files changed, root cause, fix strategy, test command run, and TEST_RESULT=PASSED|FAILED.
Also print: FIX_CONFIDENCE=high|medium|low, FIX_STRATEGY=..., TEST_COMMAND=..., TEST_RESULT=...
"""


def run_cursor_agent(
    *,
    repo_root: Path,
    prompt: str,
    cursor_bin: str = "cursor",
    model: str = "composer-2.5",
    api_key: str | None = None,
    dry_run: bool = False,
    timeout_seconds: int = 1800,
) -> subprocess.CompletedProcess[str] | None:
    if dry_run:
        print("[dry-run] Would run cursor agent with prompt:\n", prompt[:500], "...")
        return None

    env = os.environ.copy()
    if api_key:
        env["CURSOR_API_KEY"] = api_key

    cmd = [
        cursor_bin,
        "agent",
        "--print",
        "--force",
        "--trust",
        "--approve-mcps",
        "--workspace",
        str(repo_root),
        "--model",
        model,
        prompt,
    ]

    return subprocess.run(
        cmd,
        cwd=repo_root,
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout_seconds,
        check=False,
    )
