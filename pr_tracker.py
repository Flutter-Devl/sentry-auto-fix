#!/usr/bin/env python3
"""Track autofix PRs and notify Slack when Bitbucket reports them MERGED."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests

from slack_notify import notify_run_outcome


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _state_path(state_dir: Path) -> Path:
    return state_dir / "tracked-prs.json"


def load_tracked(state_dir: Path) -> list[dict[str, Any]]:
    path = _state_path(state_dir)
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    if isinstance(data, list):
        return data
    return data.get("prs", [])


def save_tracked(state_dir: Path, prs: list[dict[str, Any]]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    _state_path(state_dir).write_text(
        json.dumps({"prs": prs}, indent=2) + "\n", encoding="utf-8"
    )


def track_pr(
    state_dir: Path,
    *,
    pr_id: int,
    pr_url: str,
    branch: str = "",
    title: str = "",
    issue_short_id: str = "",
    issue_tier: str = "",
    issue_url: str = "",
) -> None:
    prs = load_tracked(state_dir)
    for row in prs:
        if int(row.get("pr_id", -1)) == int(pr_id):
            row.update(
                {
                    "pr_url": pr_url or row.get("pr_url", ""),
                    "branch": branch or row.get("branch", ""),
                    "title": title or row.get("title", ""),
                    "issue_short_id": issue_short_id or row.get("issue_short_id", ""),
                    "issue_tier": issue_tier or row.get("issue_tier", ""),
                    "issue_url": issue_url or row.get("issue_url", ""),
                    "updated_at": _now(),
                }
            )
            save_tracked(state_dir, prs)
            return
    prs.append(
        {
            "pr_id": int(pr_id),
            "pr_url": pr_url,
            "branch": branch,
            "title": title,
            "issue_short_id": issue_short_id,
            "issue_tier": issue_tier,
            "issue_url": issue_url,
            "created_at": _now(),
            "updated_at": _now(),
            "merged_notified": False,
        }
    )
    save_tracked(state_dir, prs)


def _session(access_token: str, auth: str, email: str) -> requests.Session:
    session = requests.Session()
    session.headers["Accept"] = "application/json"
    if auth == "basic" and email:
        session.auth = (email, access_token)
    else:
        session.headers["Authorization"] = f"Bearer {access_token}"
    return session


def fetch_pr(
    session: requests.Session,
    *,
    workspace: str,
    repo_slug: str,
    pr_id: int,
) -> dict[str, Any]:
    url = (
        f"https://api.bitbucket.org/2.0/repositories/"
        f"{workspace}/{repo_slug}/pullrequests/{pr_id}"
    )
    resp = session.get(url, timeout=30)
    resp.raise_for_status()
    return resp.json()


def poll_merged(
    state_dir: Path,
    *,
    workspace: str,
    repo_slug: str,
    access_token: str,
    auth: str = "bearer",
    email: str = "",
    webhook_url: str = "",
    bot_token: str = "",
    channel_id: str = "",
    profile: str = "flutter",
    notify: bool = True,
) -> int:
    """Check tracked PRs; Slack-notify newly MERGED ones. Returns notify count."""
    prs = load_tracked(state_dir)
    if not prs:
        print("pr-tracker: no tracked PRs")
        return 0

    session = _session(access_token, auth, email)
    notified = 0

    for row in prs:
        if row.get("merged_notified"):
            continue
        pr_id = int(row["pr_id"])
        try:
            data = fetch_pr(
                session, workspace=workspace, repo_slug=repo_slug, pr_id=pr_id
            )
        except requests.HTTPError as exc:
            print(f"pr-tracker: fetch PR {pr_id} failed: {exc}")
            continue

        state = (data.get("state") or "").upper()
        row["bb_state"] = state
        row["updated_at"] = _now()
        if state != "MERGED":
            continue

        merged_by = ""
        actor = data.get("closed_by") or data.get("updated_by") or {}
        if isinstance(actor, dict):
            merged_by = (
                actor.get("display_name")
                or actor.get("nickname")
                or actor.get("uuid")
                or ""
            )
        merge_commit = ""
        merge = data.get("merge_commit") or {}
        if isinstance(merge, dict):
            merge_commit = merge.get("hash", "")[:12]

        pr_url = (
            (data.get("links") or {}).get("html", {}).get("href")
            or row.get("pr_url")
            or ""
        )
        title = data.get("title") or row.get("title") or ""
        branch = (
            ((data.get("source") or {}).get("branch") or {}).get("name")
            or row.get("branch")
            or ""
        )

        detail_parts = [
            f"Title: {title}" if title else "",
            f"Merged by: {merged_by}" if merged_by else "",
            f"Merge commit: `{merge_commit}`" if merge_commit else "",
        ]
        detail = " | ".join(p for p in detail_parts if p)

        can_notify = notify and (
            (bot_token and channel_id) or webhook_url
        )
        if can_notify:
            notify_run_outcome(
                profile=profile,
                event="pr_merged",
                issue_short_id=row.get("issue_short_id", ""),
                issue_tier=row.get("issue_tier", ""),
                branch=branch,
                pr_url=pr_url,
                issue_url=row.get("issue_url", ""),
                repo_slug=repo_slug,
                detail=detail,
                title=title,
                webhook_url=webhook_url,
                bot_token=bot_token,
                channel_id=channel_id,
            )
            print(f"pr-tracker: Slack notified MERGED PR #{pr_id}")
        else:
            print(f"pr-tracker: MERGED PR #{pr_id} (Slack skipped)")

        row["merged_notified"] = True
        row["merged_at"] = _now()
        row["merged_by"] = merged_by
        notified += 1

    save_tracked(state_dir, prs)
    print(f"pr-tracker: notified={notified}")
    return notified


def main() -> int:
    parser = argparse.ArgumentParser(description="Track / poll autofix Bitbucket PRs")
    parser.add_argument("--state-dir", required=True)
    sub = parser.add_subparsers(dest="command", required=True)

    track = sub.add_parser("track")
    track.add_argument("--pr-id", type=int, required=True)
    track.add_argument("--pr-url", required=True)
    track.add_argument("--branch", default="")
    track.add_argument("--title", default="")
    track.add_argument("--issue-short-id", default="")
    track.add_argument("--issue-tier", default="")
    track.add_argument("--issue-url", default="")

    poll = sub.add_parser("poll-merged")
    poll.add_argument("--workspace", required=True)
    poll.add_argument("--repo-slug", required=True)
    poll.add_argument("--access-token", default=os.environ.get("BITBUCKET_ACCESS_TOKEN", ""))
    poll.add_argument("--auth", default="bearer")
    poll.add_argument("--email", default="")
    poll.add_argument("--webhook-url", default=os.environ.get("SLACK_WEBHOOK_URL", ""))
    poll.add_argument("--bot-token", default=os.environ.get("SLACK_BOT_TOKEN", ""))
    poll.add_argument(
        "--channel-id",
        default=os.environ.get(
            "SLACK_CHANNEL_ID",
            os.environ.get("SLACK_REVIEW_CHANNEL_ID", ""),
        ),
    )
    poll.add_argument("--profile", default="flutter")
    poll.add_argument("--no-notify", action="store_true")

    args = parser.parse_args()
    state_dir = Path(args.state_dir)

    if args.command == "track":
        track_pr(
            state_dir,
            pr_id=args.pr_id,
            pr_url=args.pr_url,
            branch=args.branch,
            title=args.title,
            issue_short_id=args.issue_short_id,
            issue_tier=args.issue_tier,
            issue_url=args.issue_url,
        )
        print(f"pr-tracker: tracked PR #{args.pr_id}")
        return 0

    if not args.access_token:
        print("BITBUCKET_ACCESS_TOKEN required", file=sys.stderr)
        return 1

    poll_merged(
        state_dir,
        workspace=args.workspace,
        repo_slug=args.repo_slug,
        access_token=args.access_token,
        auth=args.auth,
        email=args.email,
        webhook_url=args.webhook_url,
        bot_token=args.bot_token,
        channel_id=args.channel_id,
        profile=args.profile,
        notify=not args.no_notify,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
