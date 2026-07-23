#!/usr/bin/env python3
"""Store and replay lessons from rejected sentry-auto-fix PRs."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

LESSONS_FILENAME = "rejection-lessons.json"
MAX_PROMPT_LESSONS = 12

TAG_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("beforeSend", re.compile(r"before\s*send|_sentryBeforeSend|sentry\s*filter", re.I)),
    ("app_hang", re.compile(r"app\s*hang|anr|watchdog", re.I)),
    ("vendor_noise", re.compile(r"vendor|third[- ]party|adjust|iterable|launchdarkly", re.I)),
    ("filter_only", re.compile(r"filter|suppress|hide\s*event", re.I)),
    ("test_missing", re.compile(r"no\s*test|missing\s*test|add\s*test", re.I)),
    ("scope_too_large", re.compile(r"too\s*large|unrelated|refactor|drive[- ]by", re.I)),
]


def lessons_path(state_dir: Path) -> Path:
    return state_dir / LESSONS_FILENAME


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def infer_tags(reason: str, extra: list[str] | None = None) -> list[str]:
    tags = list(extra or [])
    for name, pattern in TAG_PATTERNS:
        if pattern.search(reason) and name not in tags:
            tags.append(name)
    return tags


def load_lessons(state_dir: Path) -> list[dict[str, Any]]:
    path = lessons_path(state_dir)
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return []
    return data if isinstance(data, list) else []


def save_lessons(state_dir: Path, lessons: list[dict[str, Any]]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    lessons_path(state_dir).write_text(
        json.dumps(lessons, indent=2) + "\n", encoding="utf-8"
    )


def _lesson_key(lesson: dict[str, Any]) -> str:
    return f"{lesson.get('issue_short_id', '')}|{lesson.get('branch', '')}|{lesson.get('reason', '')[:80]}"


def record_lesson(
    state_dir: Path,
    *,
    issue_short_id: str,
    reason: str,
    branch: str = "",
    reviewer: str = "",
    never_do: str = "",
    tags: list[str] | None = None,
    source: str = "manual",
) -> dict[str, Any]:
    reason = reason.strip()
    if not reason:
        raise ValueError("reason is required")

    lesson = {
        "issue_short_id": issue_short_id.strip().upper(),
        "branch": branch.strip(),
        "rejected_at": _utc_now(),
        "reviewer": reviewer.strip(),
        "reason": reason,
        "never_do": (never_do or reason).strip(),
        "tags": infer_tags(reason, tags),
        "source": source,
    }

    lessons = load_lessons(state_dir)
    key = _lesson_key(lesson)
    lessons = [item for item in lessons if _lesson_key(item) != key]
    lessons.insert(0, lesson)
    lessons = lessons[:50]
    save_lessons(state_dir, lessons)
    return lesson


def format_for_prompt(state_dir: Path, *, limit: int = MAX_PROMPT_LESSONS) -> str:
    lessons = load_lessons(state_dir)[:limit]
    if not lessons:
        return "(none recorded yet)"

    lines: list[str] = []
    for item in lessons:
        sid = item.get("issue_short_id") or "UNKNOWN"
        never = item.get("never_do") or item.get("reason") or ""
        tags = ", ".join(item.get("tags") or [])
        tag_suffix = f" [tags: {tags}]" if tags else ""
        lines.append(f"- {sid}: {never}{tag_suffix}")
    return "\n".join(lines)


def list_lessons(state_dir: Path) -> None:
    lessons = load_lessons(state_dir)
    if not lessons:
        print("(no rejection lessons recorded)")
        return
    for idx, item in enumerate(lessons, start=1):
        print(
            f"{idx}. {item.get('issue_short_id', '?')} "
            f"({item.get('rejected_at', '?')}) — {item.get('reason', '')}"
        )


def sync_from_bitbucket(
    state_dir: Path,
    *,
    workspace: str,
    repo_slug: str,
    access_token: str,
    auth: str = "bearer",
    email: str = "",
) -> int:
    from bitbucket_client import BitbucketClient

    client = BitbucketClient(
        workspace=workspace,
        repo_slug=repo_slug,
        access_token=access_token if auth == "bearer" else None,
        username=email if auth == "basic" else None,
        app_password=access_token if auth == "basic" else None,
    )

    recorded = 0
    existing = {_lesson_key(item) for item in load_lessons(state_dir)}

    for state in ("DECLINED", "OPEN"):
        url = f"{client.base}/pullrequests"
        params: dict[str, Any] = {
            "state": state,
            "pagelen": 50,
            "q": 'source.branch.name ~ "fix/sentry-"',
        }
        resp = client.session.get(url, params=params, timeout=60)
        resp.raise_for_status()
        for pr in resp.json().get("values", []):
            branch = (
                pr.get("source", {}).get("branch", {}).get("name") or ""
            )
            if not branch.startswith("fix/sentry-"):
                continue

            short_id = _short_id_from_branch(branch)
            if state == "OPEN":
                feedback = _open_pr_feedback(client, pr["id"])
                if not feedback:
                    continue
            else:
                feedback = _declined_pr_reason(pr, client)

            if not feedback:
                continue

            lesson = {
                "issue_short_id": short_id,
                "branch": branch,
                "rejected_at": _utc_now(),
                "reviewer": _reviewer_from_pr(pr),
                "reason": feedback,
                "never_do": feedback,
                "tags": infer_tags(feedback),
                "source": f"bitbucket:{state.lower()}",
            }
            key = _lesson_key(lesson)
            if key in existing:
                continue
            lessons = load_lessons(state_dir)
            lessons.insert(0, lesson)
            save_lessons(state_dir, lessons[:50])
            existing.add(key)
            recorded += 1
            print(f"recorded: {short_id} — {feedback[:120]}")

    print(f"sync complete: {recorded} new lesson(s)")
    return recorded


def _short_id_from_branch(branch: str) -> str:
    # fix/sentry-robo-staging-f8-slug -> ROBO-STAGING-F8
    slug = branch.removeprefix("fix/sentry-")
    parts = slug.split("-")
    if len(parts) >= 3:
        return "-".join(parts[:3]).upper()
    return slug.upper()


def _reviewer_from_pr(pr: dict[str, Any]) -> str:
    reviewers = pr.get("reviewers") or []
    if reviewers:
        return reviewers[0].get("display_name") or reviewers[0].get("nickname") or ""
    return ""


def _declined_pr_reason(pr: dict[str, Any], client: Any | None = None) -> str:
    """Prefer reviewer comment text; fall back to description/title."""
    pr_id = pr.get("id")
    if client is not None and pr_id is not None:
        try:
            from pr_tracker import extract_rejection_reason

            # Reconstruct workspace/repo from client.base
            # .../repositories/{workspace}/{repo_slug}
            parts = client.base.rstrip("/").split("/")
            workspace, repo_slug = parts[-2], parts[-1]
            return extract_rejection_reason(
                client.session,
                workspace=workspace,
                repo_slug=repo_slug,
                pr_id=int(pr_id),
                pr_data=pr,
            )
        except Exception:
            pass

    title = pr.get("title") or ""
    desc = pr.get("description") or ""
    for text in (desc, title):
        if "reject" in text.lower() or "not merge" in text.lower():
            return text.strip()[:500]
    return f"PR declined: {title}".strip()[:500]


def _open_pr_feedback(client: Any, pr_id: int) -> str:
    """Return feedback text if PR has reviewer rejection / changes-requested signal."""
    url = f"{client.base}/pullrequests/{pr_id}/comments"
    resp = client.session.get(url, params={"pagelen": 20}, timeout=60)
    if resp.status_code != 200:
        return ""

    needles = (
        "reject",
        "do not merge",
        "changes requested",
        "not acceptable",
        "beforesend",
        "before_send",
        "filter only",
        "no_action",
    )
    for comment in resp.json().get("values", []):
        content = (comment.get("content") or {}).get("raw") or ""
        lowered = content.lower()
        if any(n in lowered for n in needles):
            return content.strip()[:500]
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description="Rejection lessons for sentry-auto-fix")
    parser.add_argument("--state-dir", required=True)
    sub = parser.add_subparsers(dest="command", required=True)

    record = sub.add_parser("record")
    record.add_argument("--issue-short-id", required=True)
    record.add_argument("--reason", required=True)
    record.add_argument("--branch", default="")
    record.add_argument("--reviewer", default="")
    record.add_argument("--never-do", default="")
    record.add_argument("--tags", default="")

    sub.add_parser("list")
    sub.add_parser("prompt")

    sync = sub.add_parser("sync-bitbucket")
    sync.add_argument("--workspace", required=True)
    sync.add_argument("--repo-slug", required=True)
    sync.add_argument("--access-token", required=True)
    sync.add_argument("--auth", default="bearer")
    sync.add_argument("--email", default="")

    args = parser.parse_args()
    state_dir = Path(args.state_dir)

    if args.command == "record":
        tags = [t.strip() for t in args.tags.split(",") if t.strip()] if args.tags else None
        lesson = record_lesson(
            state_dir,
            issue_short_id=args.issue_short_id,
            reason=args.reason,
            branch=args.branch,
            reviewer=args.reviewer,
            never_do=args.never_do,
            tags=tags,
        )
        print(json.dumps(lesson, indent=2))
        return 0

    if args.command == "list":
        list_lessons(state_dir)
        return 0

    if args.command == "prompt":
        print(format_for_prompt(state_dir))
        return 0

    if args.command == "sync-bitbucket":
        sync_from_bitbucket(
            state_dir,
            workspace=args.workspace,
            repo_slug=args.repo_slug,
            access_token=args.access_token,
            auth=args.auth,
            email=args.email,
        )
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
