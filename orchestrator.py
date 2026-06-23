#!/usr/bin/env python3
"""
Sentry → Cursor Agent → Bitbucket PR (local, self-hosted).

Polls Sentry for unresolved issues (or processes one issue via --issue-id),
runs Cursor Agent to fix, pushes branch, opens Bitbucket PR.

Usage:
  python orchestrator.py poll
  python orchestrator.py fix --issue-id 1234567890
  python orchestrator.py webhook   # optional local webhook receiver
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

from agent_runner import build_fix_prompt, run_cursor_agent
from bitbucket_client import BitbucketClient
from sentry_client import SentryClient
from state import IssueRecord, StateStore, utc_now_iso


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        os.environ.setdefault(key.strip(), value)


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.lower() in ("1", "true", "yes", "on")


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def slugify(text: str, max_len: int = 40) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", text.lower()).strip("-")
    return slug[:max_len] or "issue"


def git_run(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=repo,
        text=True,
        capture_output=True,
        check=check,
    )


def has_uncommitted_changes(repo: Path) -> bool:
    return bool(git_run(repo, "status", "--porcelain").stdout.strip())


def branch_name_for_issue(short_id: str, title: str) -> str:
    return f"fix/sentry-{short_id.lower()}-{slugify(title)}"


def ensure_clean_base(repo: Path, base_branch: str, dry_run: bool) -> None:
    if dry_run:
        return
    git_run(repo, "fetch", "origin", base_branch)
    git_run(repo, "checkout", base_branch)
    git_run(repo, "pull", "--ff-only", "origin", base_branch)


def create_branch(repo: Path, branch: str, dry_run: bool) -> None:
    if dry_run:
        print(f"[dry-run] git checkout -b {branch}")
        return
    git_run(repo, "checkout", "-b", branch)


def push_branch(repo: Path, branch: str, dry_run: bool) -> None:
    if dry_run:
        print(f"[dry-run] git push -u origin {branch}")
        return
    git_run(repo, "push", "-u", "origin", branch)


def _require_env(*names: str) -> None:
    missing = [n for n in names if not os.environ.get(n)]
    if missing:
        raise SystemExit(f"Missing required config in config.env: {', '.join(missing)}")


def process_issue(issue_id: str | None = None) -> int:
    script_dir = Path(__file__).resolve().parent
    load_env_file(script_dir / "config.env")

    if not os.environ.get("DRY_RUN", "").lower() in ("1", "true", "yes"):
        _require_env(
            "SENTRY_AUTH_TOKEN",
            "SENTRY_ORG_SLUG",
            "BITBUCKET_WORKSPACE",
            "BITBUCKET_REPO_SLUG",
        )
        has_bb_token = bool(os.environ.get("BITBUCKET_ACCESS_TOKEN"))
        has_bb_basic = bool(
            os.environ.get("BITBUCKET_USERNAME")
            and os.environ.get("BITBUCKET_APP_PASSWORD")
        )
        if not has_bb_token and not has_bb_basic:
            raise SystemExit(
                "Missing Bitbucket auth: set BITBUCKET_ACCESS_TOKEN "
                "or BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD in config.env"
            )

    repo_root = Path(os.environ.get("REPO_ROOT", script_dir.parent.parent)).resolve()
    base_branch = os.environ.get("GIT_BASE_BRANCH", "develop")
    dry_run = env_bool("DRY_RUN", False)

    sentry = SentryClient(
        auth_token=os.environ["SENTRY_AUTH_TOKEN"],
        org_slug=os.environ["SENTRY_ORG_SLUG"],
        region_url=os.environ.get("SENTRY_REGION_URL", "https://us.sentry.io"),
        project_slug=os.environ.get("SENTRY_PROJECT_SLUG"),
    )

    state = StateStore(script_dir / ".state" / "processed_issues.json")

    if issue_id:
        issues = [
            i
            for i in sentry.list_unresolved_issues(
                query=f"id:{issue_id}",
                limit=1,
            )
        ]
        if not issues:
            # Fetch by scanning if id: filter unsupported
            issues = [
                i
                for i in sentry.list_unresolved_issues(query="is:unresolved", limit=100)
                if i.id == issue_id
            ]
    else:
        query = os.environ.get("SENTRY_ISSUE_QUERY", "is:unresolved level:error")
        page_size = min(100, env_int("SENTRY_PAGE_SIZE", 100))
        max_pages = max(1, env_int("SENTRY_MAX_PAGES", 10))
        triage_simple_first = env_bool("SENTRY_TRIAGE_SIMPLE_FIRST", True)
        issues = []
        for page, _link in sentry.iter_unresolved_issue_pages(
            query=query,
            limit=page_size,
            max_pages=max_pages,
        ):
            issues.extend(page)
        from sentry_pagination import select_tier_candidates

        candidates, _tier = select_tier_candidates(
            issues,
            branched=set(),
            excluded=set(),
            triage_simple_first=triage_simple_first,
        )
        issues = [
            i
            for i in issues
            if any(c["short_id"] == i.short_id for c in candidates)
        ]
        limit = env_int("SENTRY_ISSUE_LIMIT", 5)
        issues = issues[:limit]

    max_per_run = env_int("MAX_ISSUES_PER_RUN", 1)
    processed_count = 0

    for issue in issues:
        if not state.should_process(issue.id, issue.last_seen):
            print(f"Skip {issue.short_id} (already processed)")
            continue

        if processed_count >= max_per_run:
            break

        print(f"Processing {issue.short_id}: {issue.title}")

        try:
            event = sentry.get_latest_event(issue.id)
            stack_hint = _format_stack_hint(event)
        except Exception as exc:  # noqa: BLE001
            stack_hint = f"(Could not fetch latest event: {exc})"

        branch = branch_name_for_issue(issue.short_id, issue.title)

        try:
            if has_uncommitted_changes(repo_root) and not dry_run:
                raise RuntimeError(
                    "Repository has uncommitted changes. Commit or stash before running."
                )

            ensure_clean_base(repo_root, base_branch, dry_run)
            create_branch(repo_root, branch, dry_run)

            prompt = build_fix_prompt(
                issue_short_id=issue.short_id,
                issue_title=issue.title,
                issue_url=issue.permalink,
                issue_id=issue.id,
                stack_hint=stack_hint,
                base_branch=base_branch,
                branch_name=branch,
            )

            result = run_cursor_agent(
                repo_root=repo_root,
                prompt=prompt,
                cursor_bin=os.environ.get("CURSOR_BIN", "cursor"),
                model=os.environ.get("CURSOR_AGENT_MODEL", "composer-2.5"),
                api_key=os.environ.get("CURSOR_API_KEY"),
                dry_run=dry_run,
            )

            if result and result.returncode != 0:
                raise RuntimeError(
                    f"Cursor agent failed (exit {result.returncode}):\n"
                    f"{result.stderr[-2000:]}"
                )

            if dry_run:
                state.put(
                    IssueRecord(
                        issue_id=issue.id,
                        short_id=issue.short_id,
                        title=issue.title,
                        status="skipped",
                        branch=branch,
                        pr_url=None,
                        processed_at=utc_now_iso(),
                        last_seen=issue.last_seen,
                    )
                )
                processed_count += 1
                continue

            diff = git_run(repo_root, "diff", "--stat", "HEAD", check=False)
            if not diff.stdout.strip() and env_bool("SKIP_IF_NO_CHANGES", True):
                print(f"No changes for {issue.short_id}")
                git_run(repo_root, "checkout", base_branch)
                git_run(repo_root, "branch", "-D", branch, check=False)
                state.put(
                    IssueRecord(
                        issue_id=issue.id,
                        short_id=issue.short_id,
                        title=issue.title,
                        status="no_changes",
                        branch=None,
                        pr_url=None,
                        processed_at=utc_now_iso(),
                        last_seen=issue.last_seen,
                    )
                )
                processed_count += 1
                continue

            push_branch(repo_root, branch, dry_run=False)

            bb = BitbucketClient(
                workspace=os.environ["BITBUCKET_WORKSPACE"],
                repo_slug=os.environ["BITBUCKET_REPO_SLUG"],
                username=os.environ.get("BITBUCKET_USERNAME"),
                app_password=os.environ.get("BITBUCKET_APP_PASSWORD"),
                access_token=os.environ.get("BITBUCKET_ACCESS_TOKEN"),
            )

            pr_body = _pr_description(issue, result.stdout if result else "")
            pr = bb.create_pull_request(
                title=f"fix(sentry): {issue.short_id} — {issue.title[:80]}",
                description=pr_body,
                source_branch=branch,
                destination_branch=base_branch,
                draft=env_bool("PR_DRAFT", True),
            )

            print(f"PR created: {pr.url}")
            state.put(
                IssueRecord(
                    issue_id=issue.id,
                    short_id=issue.short_id,
                    title=issue.title,
                    status="success",
                    branch=branch,
                    pr_url=pr.url,
                    processed_at=utc_now_iso(),
                    last_seen=issue.last_seen,
                )
            )
            processed_count += 1

        except Exception as exc:  # noqa: BLE001
            print(f"Failed {issue.short_id}: {exc}", file=sys.stderr)
            state.put(
                IssueRecord(
                    issue_id=issue.id,
                    short_id=issue.short_id,
                    title=issue.title,
                    status="failed",
                    branch=branch,
                    pr_url=None,
                    processed_at=utc_now_iso(),
                    last_seen=issue.last_seen,
                    error=str(exc),
                )
            )
            try:
                git_run(repo_root, "checkout", base_branch, check=False)
            except Exception:  # noqa: BLE001
                pass

    return 0


def _format_stack_hint(event: dict) -> str:
    entries = event.get("entries") or []
    for entry in entries:
        if entry.get("type") == "exception":
            values = entry.get("data", {}).get("values", [])
            lines = []
            for val in values[:3]:
                lines.append(f"{val.get('type')}: {val.get('value')}")
                for frame in (val.get("stacktrace") or {}).get("frames", [])[-8:]:
                    fn = frame.get("filename") or frame.get("absPath")
                    line = frame.get("lineNo")
                    func = frame.get("function")
                    lines.append(f"  at {fn}:{line} in {func}")
            return "\n".join(lines) if lines else str(entry)
    return str(event.get("title") or event.get("message") or "No stack in latest event")


def _pr_description(issue, agent_output: str) -> str:
    return f"""## Sentry auto-fix

**Issue:** [{issue.short_id}]({issue.permalink})
**Title:** {issue.title}

### Agent summary
```
{agent_output[-4000:] if agent_output else "N/A"}
```

---
*Opened by local `scripts/sentry-auto-fix` workflow. Please review before merge.*
"""


def cmd_poll(_: argparse.Namespace) -> int:
    return process_issue(issue_id=None)


def cmd_fix(args: argparse.Namespace) -> int:
    if not args.issue_id:
        print("--issue-id is required", file=sys.stderr)
        return 1
    return process_issue(issue_id=args.issue_id)


def cmd_webhook(args: argparse.Namespace) -> int:
    from webhook_server import run_webhook_server

    run_webhook_server(host=args.host, port=args.port)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Sentry auto-fix orchestrator")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("poll", help="Poll Sentry and process new unresolved issues")
    fix_p = sub.add_parser("fix", help="Process a single Sentry issue by id")
    fix_p.add_argument("--issue-id", required=True)

    wh = sub.add_parser("webhook", help="Run local Sentry webhook receiver")
    wh.add_argument("--host", default="127.0.0.1")
    wh.add_argument("--port", type=int, default=8765)

    args = parser.parse_args()
    if args.command == "poll":
        return cmd_poll(args)
    if args.command == "fix":
        return cmd_fix(args)
    if args.command == "webhook":
        return cmd_webhook(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
