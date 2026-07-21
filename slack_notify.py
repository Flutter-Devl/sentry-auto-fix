#!/usr/bin/env python3
"""Post sentry-auto-fix run outcomes to Slack via Incoming Webhook."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any


def send_slack(
    webhook_url: str,
    *,
    text: str,
    blocks: list[dict[str, Any]] | None = None,
) -> None:
    payload: dict[str, Any] = {"text": text}
    if blocks:
        payload["blocks"] = blocks

    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        webhook_url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status >= 400:
                raise RuntimeError(f"Slack HTTP {response.status}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Slack webhook failed: {exc}") from exc


def _mrkdwn_section(text: str) -> dict[str, Any]:
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def build_run_outcome_message(
    *,
    profile: str,
    event: str,
    issue_short_id: str = "",
    issue_tier: str = "",
    branch: str = "",
    pr_url: str = "",
    issue_url: str = "",
    repo_slug: str = "",
    detail: str = "",
) -> tuple[str, list[dict[str, Any]]]:
    labels = {
        "run_started": ("🔧", "Fix cycle started"),
        "no_action": ("⏭️", "No actionable issue"),
        "pr_created": ("📋", "Draft PR created"),
        "branch_pushed": ("📤", "Branch pushed (no auto-PR)"),
        "quality_gate_failed": ("🚫", "Quality gate failed — PR blocked"),
        "agent_failed": ("⚠️", "Agent run failed"),
    }
    emoji, title = labels.get(event, ("ℹ️", event.replace("_", " ").title()))

    fallback = f"{emoji} Sentry Auto-Fix [{profile}] — {title}"
    if issue_short_id:
        fallback += f" — {issue_short_id}"

    lines = [
        f"{emoji} *{title}*",
        f"*Profile:* `{profile}`",
    ]
    if issue_short_id:
        lines.append(f"*Issue:* `{issue_short_id}`{f' ({issue_tier})' if issue_tier else ''}")
    if branch:
        lines.append(f"*Branch:* `{branch}`")
    if pr_url:
        lines.append(f"*PR:* <{pr_url}|Open pull request>")
    elif branch and repo_slug:
        lines.append(
            f"*PR:* create manually in Bitbucket for `{branch}`"
        )
    if issue_url:
        lines.append(f"*Sentry:* <{issue_url}|View issue>")
    if detail:
        lines.append(f"*Detail:* {detail}")

    blocks = [_mrkdwn_section("\n".join(lines))]
    return fallback, blocks


def notify_run_outcome(
    *,
    webhook_url: str,
    profile: str,
    event: str,
    issue_short_id: str = "",
    issue_tier: str = "",
    branch: str = "",
    pr_url: str = "",
    issue_url: str = "",
    repo_slug: str = "",
    detail: str = "",
) -> None:
    text, blocks = build_run_outcome_message(
        profile=profile,
        event=event,
        issue_short_id=issue_short_id,
        issue_tier=issue_tier,
        branch=branch,
        pr_url=pr_url,
        issue_url=issue_url,
        repo_slug=repo_slug,
        detail=detail,
    )
    send_slack(webhook_url, text=text, blocks=blocks)


def main() -> int:
    parser = argparse.ArgumentParser(description="Slack notifications for sentry-auto-fix")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run-outcome")
    run.add_argument("--webhook-url", default=os.environ.get("SLACK_WEBHOOK_URL", ""))
    run.add_argument("--profile", default="flutter")
    run.add_argument("--event", required=True)
    run.add_argument("--issue-short-id", default="")
    run.add_argument("--issue-tier", default="")
    run.add_argument("--branch", default="")
    run.add_argument("--pr-url", default="")
    run.add_argument("--issue-url", default="")
    run.add_argument("--repo-slug", default="")
    run.add_argument("--detail", default="")

    test = sub.add_parser("test")
    test.add_argument("--webhook-url", default=os.environ.get("SLACK_WEBHOOK_URL", ""))
    test.add_argument("--profile", default="flutter")

    args = parser.parse_args()
    webhook = (args.webhook_url or "").strip()
    if not webhook:
        print("SLACK_WEBHOOK_URL is not set", file=sys.stderr)
        return 1

    if args.command == "test":
        notify_run_outcome(
            webhook_url=webhook,
            profile=args.profile,
            event="run_started",
            detail="Slack webhook test from sentry-auto-fix",
        )
        print("Slack test message sent")
        return 0

    notify_run_outcome(
        webhook_url=webhook,
        profile=args.profile,
        event=args.event,
        issue_short_id=args.issue_short_id,
        issue_tier=args.issue_tier,
        branch=args.branch,
        pr_url=args.pr_url,
        issue_url=args.issue_url,
        repo_slug=args.repo_slug,
        detail=args.detail,
    )
    print(f"Slack notified: {args.event}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
