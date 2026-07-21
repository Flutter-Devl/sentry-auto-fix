#!/usr/bin/env python3
"""Post sentry-auto-fix run outcomes to Slack.

Preferred: Bot token + channel ID (chat.postMessage) — no Incoming Webhook.
Fallback: Incoming Webhook URL.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

# Slack section text hard limit is ~3000; keep headroom for markup.
_MAX_DETAIL_CHARS = 2500
_CHAT_POST_URL = "https://slack.com/api/chat.postMessage"


def send_slack_webhook(
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


def send_slack_bot(
    bot_token: str,
    channel_id: str,
    *,
    text: str,
    blocks: list[dict[str, Any]] | None = None,
) -> None:
    """Post via Slack Web API chat.postMessage (channel ID like C0BGPF244H3)."""
    payload: dict[str, Any] = {
        "channel": channel_id.strip(),
        "text": text,
    }
    if blocks:
        payload["blocks"] = blocks

    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        _CHAT_POST_URL,
        data=data,
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {bot_token.strip()}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Slack API failed: {exc}") from exc

    if not body.get("ok"):
        raise RuntimeError(
            f"Slack API error: {body.get('error', 'unknown')} "
            f"(invite the bot to the channel if channel_not_found / not_in_channel)"
        )


def send_slack(
    *,
    text: str,
    blocks: list[dict[str, Any]] | None = None,
    bot_token: str = "",
    channel_id: str = "",
    webhook_url: str = "",
) -> None:
    """Prefer bot+channel; else webhook."""
    if bot_token.strip() and channel_id.strip():
        send_slack_bot(bot_token, channel_id, text=text, blocks=blocks)
        return
    if webhook_url.strip():
        send_slack_webhook(webhook_url, text=text, blocks=blocks)
        return
    raise RuntimeError(
        "Slack not configured: set SLACK_BOT_TOKEN + SLACK_CHANNEL_ID "
        "(preferred) or SLACK_WEBHOOK_URL"
    )


def slack_configured(
    *,
    bot_token: str = "",
    channel_id: str = "",
    webhook_url: str = "",
) -> bool:
    if bot_token.strip() and channel_id.strip():
        return True
    return bool(webhook_url.strip())


def _mrkdwn_section(text: str) -> dict[str, Any]:
    return {"type": "section", "text": {"type": "mrkdwn", "text": text}}


def _truncate(text: str, limit: int = _MAX_DETAIL_CHARS) -> str:
    text = (text or "").strip()
    if len(text) <= limit:
        return text
    return text[: limit - 20] + "\n… _(truncated)_"


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
    title: str = "",
    gate_reason: str = "",
    cg_status: str = "",
) -> tuple[str, list[dict[str, Any]]]:
    labels = {
        "run_started": ("🔧", "Fix cycle started"),
        "no_action": ("⏭️", "No actionable issue"),
        "pr_created": ("📋", "Draft PR created"),
        "pr_merged": ("✅", "PR merged"),
        "branch_pushed": ("📤", "Branch pushed (no auto-PR)"),
        "quality_gate_failed": ("🚫", "Quality gate failed — PR blocked"),
        "codeguardian_passed": ("🛡️", "CodeGuardian passed"),
        "codeguardian_failed": ("🛑", "CodeGuardian failed — PR blocked"),
        "agent_failed": ("⚠️", "Agent run failed"),
    }
    emoji, heading = labels.get(event, ("ℹ️", event.replace("_", " ").title()))

    fallback = f"{emoji} Sentry Auto-Fix [{profile}] — {heading}"
    if issue_short_id:
        fallback += f" — {issue_short_id}"

    lines = [
        f"{emoji} *{heading}*",
        f"*Profile:* `{profile}`",
    ]
    if issue_short_id:
        lines.append(
            f"*Issue:* `{issue_short_id}`"
            f"{f' ({issue_tier})' if issue_tier else ''}"
        )
    if title:
        lines.append(f"*Title:* {title}")
    if branch:
        lines.append(f"*Branch:* `{branch}`")
    if gate_reason:
        lines.append(f"*Gate reason:* `{gate_reason}`")
    if cg_status:
        lines.append(f"*CodeGuardian:* `{cg_status}`")
    if pr_url:
        lines.append(f"*PR:* <{pr_url}|Open pull request>")
    elif branch and repo_slug and event not in ("pr_merged",):
        lines.append(f"*PR:* create manually in Bitbucket for `{branch}`")
    if issue_url:
        lines.append(f"*Sentry:* <{issue_url}|View issue>")
    if detail:
        lines.append(f"*Detail:*\n```{_truncate(detail)}```")

    blocks = [_mrkdwn_section("\n".join(lines))]
    return fallback, blocks


def notify_run_outcome(
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
    title: str = "",
    gate_reason: str = "",
    cg_status: str = "",
    bot_token: str = "",
    channel_id: str = "",
    webhook_url: str = "",
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
        title=title,
        gate_reason=gate_reason,
        cg_status=cg_status,
    )
    send_slack(
        text=text,
        blocks=blocks,
        bot_token=bot_token or os.environ.get("SLACK_BOT_TOKEN", ""),
        channel_id=channel_id or os.environ.get("SLACK_CHANNEL_ID", ""),
        webhook_url=webhook_url or os.environ.get("SLACK_WEBHOOK_URL", ""),
    )


def _add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bot-token", default=os.environ.get("SLACK_BOT_TOKEN", ""))
    parser.add_argument("--channel-id", default=os.environ.get("SLACK_CHANNEL_ID", ""))
    parser.add_argument("--webhook-url", default=os.environ.get("SLACK_WEBHOOK_URL", ""))
    parser.add_argument("--profile", default="flutter")


def main() -> int:
    parser = argparse.ArgumentParser(description="Slack notifications for sentry-auto-fix")
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run-outcome")
    _add_common_args(run)
    run.add_argument("--event", required=True)
    run.add_argument("--issue-short-id", default="")
    run.add_argument("--issue-tier", default="")
    run.add_argument("--branch", default="")
    run.add_argument("--pr-url", default="")
    run.add_argument("--issue-url", default="")
    run.add_argument("--repo-slug", default="")
    run.add_argument("--detail", default="")
    run.add_argument("--title", default="")
    run.add_argument("--gate-reason", default="")
    run.add_argument("--cg-status", default="")

    test = sub.add_parser("test")
    _add_common_args(test)

    args = parser.parse_args()
    bot = (args.bot_token or "").strip()
    channel = (args.channel_id or "").strip()
    webhook = (args.webhook_url or "").strip()

    if not slack_configured(bot_token=bot, channel_id=channel, webhook_url=webhook):
        print(
            "Set SLACK_BOT_TOKEN + SLACK_CHANNEL_ID (preferred) or SLACK_WEBHOOK_URL",
            file=sys.stderr,
        )
        return 1

    if args.command == "test":
        mode = "bot+channel" if bot and channel else "webhook"
        notify_run_outcome(
            profile=args.profile,
            event="run_started",
            detail=f"Slack test from sentry-auto-fix ({mode})",
            bot_token=bot,
            channel_id=channel,
            webhook_url=webhook,
        )
        print(f"Slack test message sent ({mode})")
        return 0

    notify_run_outcome(
        profile=args.profile,
        event=args.event,
        issue_short_id=args.issue_short_id,
        issue_tier=args.issue_tier,
        branch=args.branch,
        pr_url=args.pr_url,
        issue_url=args.issue_url,
        repo_slug=args.repo_slug,
        detail=args.detail,
        title=args.title,
        gate_reason=args.gate_reason,
        cg_status=args.cg_status,
        bot_token=bot,
        channel_id=channel,
        webhook_url=webhook,
    )
    print(f"Slack notified: {args.event}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
