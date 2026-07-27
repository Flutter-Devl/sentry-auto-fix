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
from sentry_resolve import (
    apply_outcome_to_row,
    maybe_resolve_after_merge,
    parse_iso,
)


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


def fetch_pr_comments(
    session: requests.Session,
    *,
    workspace: str,
    repo_slug: str,
    pr_id: int,
) -> list[dict[str, Any]]:
    url = (
        f"https://api.bitbucket.org/2.0/repositories/"
        f"{workspace}/{repo_slug}/pullrequests/{pr_id}/comments"
    )
    resp = session.get(url, params={"pagelen": 50}, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    return list(data.get("values") or [])


def fetch_pr_activity(
    session: requests.Session,
    *,
    workspace: str,
    repo_slug: str,
    pr_id: int,
) -> list[dict[str, Any]]:
    url = (
        f"https://api.bitbucket.org/2.0/repositories/"
        f"{workspace}/{repo_slug}/pullrequests/{pr_id}/activity"
    )
    resp = session.get(url, params={"pagelen": 50}, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    return list(data.get("values") or [])


def extract_rejection_reason(
    session: requests.Session,
    *,
    workspace: str,
    repo_slug: str,
    pr_id: int,
    pr_data: dict[str, Any],
) -> str:
    try:
        comments = fetch_pr_comments(
            session, workspace=workspace, repo_slug=repo_slug, pr_id=pr_id
        )
    except requests.HTTPError:
        comments = []

    for comment in comments:
        content = comment.get("content") or {}
        raw = (content.get("raw") or content.get("markup") or "").strip()
        if not raw:
            continue
        lower = raw.lower()
        if "automated sentry fix" in lower and "**issue:**" in lower:
            continue
        if any(
            token in lower
            for token in ("reject", "decline", "not merge", "don't merge", "do not merge")
        ):
            return raw[:800]
        if len(raw) > 20 and "fix(sentry)" not in lower:
            return raw[:800]

    try:
        activity = fetch_pr_activity(
            session, workspace=workspace, repo_slug=repo_slug, pr_id=pr_id
        )
    except requests.HTTPError:
        activity = []

    for item in activity:
        update = item.get("update") or {}
        if (update.get("state") or "").upper() == "DECLINED":
            reason = (update.get("reason") or "").strip()
            if reason:
                return reason[:800]

    desc = (pr_data.get("description") or "").strip()
    if desc and "reject" in desc.lower():
        return desc[:800]

    title = (pr_data.get("title") or "").strip()
    return f"PR declined (no reviewer comment found){f': {title}' if title else ''}"


def _merged_at(row: dict[str, Any]) -> datetime | None:
    return parse_iso(row.get("closed_at") or row.get("merged_at") or "")


def _sentry_client_from_env() -> Any | None:
    token = (os.environ.get("SENTRY_AUTH_TOKEN") or "").strip()
    org = (os.environ.get("SENTRY_ORG_SLUG") or "").strip()
    if not token or not org:
        return None
    from sentry_client import SentryClient

    return SentryClient(
        auth_token=token,
        org_slug=org,
        region_url=os.environ.get("SENTRY_REGION_URL", "https://us.sentry.io"),
        project_slug=os.environ.get("SENTRY_PROJECT_SLUG") or None,
    )


def process_sentry_resolves(
    prs: list[dict[str, Any]],
    *,
    mode: str,
    min_age_hours: float,
    max_age_days: float,
    skew_minutes: int,
    profile: str,
    repo_slug: str,
    webhook_url: str,
    bot_token: str,
    channel_id: str,
    notify: bool,
) -> int:
    """Quiet-check + auto/prompt resolve for merged autofix PRs. Returns notify count."""
    mode = (mode or "off").strip().lower()
    if mode in ("off", "false", "0", "no", ""):
        return 0

    client = _sentry_client_from_env()
    if client is None:
        print("pr-tracker: sentry resolve skipped (SENTRY_AUTH_TOKEN / ORG missing)")
        return 0

    notified = 0
    can_notify = notify and ((bot_token and channel_id) or webhook_url)

    for row in prs:
        if (row.get("bb_state") or "").upper() == "DECLINED":
            continue
        if not (
            (row.get("bb_state") or "").upper() == "MERGED" or row.get("merged_notified")
        ):
            continue

        status = (row.get("sentry_resolve_status") or "pending").lower()
        if status in (
            "resolved",
            "already_resolved",
            "skipped",
            "abandoned",
            "off",
        ):
            continue

        merged_at = _merged_at(row)
        if merged_at is None:
            continue

        short_id = (row.get("issue_short_id") or "").strip()
        outcome = maybe_resolve_after_merge(
            client,
            short_id=short_id,
            merged_at=merged_at,
            mode=mode,
            min_age_hours=min_age_hours,
            max_age_days=max_age_days,
            skew_minutes=skew_minutes,
            already_prompted=bool(row.get("sentry_resolve_prompted")),
            already_noisy_notified=bool(row.get("sentry_noisy_notified")),
        )
        apply_outcome_to_row(row, outcome)
        print(
            f"pr-tracker: sentry resolve PR #{row.get('pr_id')} "
            f"status={outcome.status} — {outcome.detail}"
        )

        if outcome.notify_event and can_notify:
            detail = outcome.detail
            if outcome.notify_event == "sentry_resolve_ready":
                detail += (
                    f"\nIssue: {short_id}"
                    f"\nCommand: ./run.sh resolve-issue {short_id}"
                )
            notify_run_outcome(
                profile=profile,
                event=outcome.notify_event,
                issue_short_id=short_id,
                issue_tier=row.get("issue_tier", ""),
                branch=row.get("branch", ""),
                pr_url=row.get("pr_url", ""),
                issue_url=row.get("issue_url", ""),
                repo_slug=repo_slug,
                detail=detail,
                title=row.get("title", ""),
                webhook_url=webhook_url,
                bot_token=bot_token,
                channel_id=channel_id,
            )
            notified += 1
            print(
                f"pr-tracker: Slack notified {outcome.notify_event} PR #{row.get('pr_id')}"
            )

    return notified


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
    sentry_resolve_mode: str = "auto",
    sentry_resolve_min_age_hours: float = 6.0,
    sentry_resolve_max_age_days: float = 14.0,
    sentry_resolve_skew_minutes: int = 5,
) -> int:
    """Check tracked PRs; Slack-notify newly MERGED/DECLINED; maybe resolve Sentry."""
    prs = load_tracked(state_dir)
    if not prs:
        print("pr-tracker: no tracked PRs")
        return 0

    session = _session(access_token, auth, email)
    notified = 0
    resolve_mode = (sentry_resolve_mode or "off").strip().lower()

    for row in prs:
        needs_fetch = not row.get("terminal_notified") or (
            resolve_mode not in ("off", "false", "0", "no", "")
            and (row.get("sentry_resolve_status") or "pending")
            not in ("resolved", "already_resolved", "skipped", "abandoned", "off")
            and (row.get("bb_state") or "").upper() != "DECLINED"
        )
        if not needs_fetch:
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
        if state not in ("MERGED", "DECLINED"):
            continue

        if row.get("terminal_notified"):
            if state == "MERGED" and not row.get("closed_at"):
                row["closed_at"] = _now()
            if state == "MERGED" and not row.get("sentry_resolve_status"):
                row["sentry_resolve_status"] = (
                    "pending"
                    if resolve_mode not in ("off", "false", "0", "no", "")
                    else "off"
                )
            continue

        actor = data.get("closed_by") or data.get("updated_by") or {}
        closed_by = ""
        if isinstance(actor, dict):
            closed_by = (
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

        if state == "MERGED":
            event = "pr_merged"
            detail_parts = [
                f"Title: {title}" if title else "",
                f"Merged by: {closed_by}" if closed_by else "",
                f"Merge commit: `{merge_commit}`" if merge_commit else "",
            ]
            if resolve_mode == "auto":
                detail_parts.append(
                    "Sentry: will auto-resolve after quiet window "
                    f"(~{sentry_resolve_min_age_hours:g}h)"
                )
            elif resolve_mode == "prompt":
                detail_parts.append(
                    "Sentry: will Slack when quiet — then run "
                    f"./run.sh resolve-issue {row.get('issue_short_id') or 'SHORT_ID'}"
                )
            row["sentry_resolve_status"] = (
                "pending"
                if resolve_mode not in ("off", "false", "0", "no", "")
                else "off"
            )
        else:
            event = "pr_declined"
            rejection_reason = extract_rejection_reason(
                session,
                workspace=workspace,
                repo_slug=repo_slug,
                pr_id=pr_id,
                pr_data=data,
            )
            detail_parts = [
                f"Title: {title}" if title else "",
                f"Declined by: {closed_by}" if closed_by else "",
                f"Rejection reason: {rejection_reason}" if rejection_reason else "",
            ]
            row["rejection_reason"] = rejection_reason
            row["sentry_resolve_status"] = "skipped"
            try:
                from rejection_lessons import record_lesson

                if rejection_reason and not rejection_reason.startswith(
                    "PR declined (no reviewer comment found)"
                ):
                    record_lesson(
                        state_dir,
                        issue_short_id=row.get("issue_short_id") or "UNKNOWN",
                        reason=rejection_reason,
                        branch=branch,
                        reviewer=closed_by,
                        source="bitbucket:declined",
                    )
            except Exception as exc:  # noqa: BLE001
                print(f"pr-tracker: record lesson failed: {exc}")
        detail = " | ".join(p for p in detail_parts if p)

        can_notify = notify and ((bot_token and channel_id) or webhook_url)
        if can_notify:
            notify_run_outcome(
                profile=profile,
                event=event,
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
            print(f"pr-tracker: Slack notified {state} PR #{pr_id}")
            notified += 1
        else:
            print(f"pr-tracker: {state} PR #{pr_id} (Slack skipped)")

        row["merged_notified"] = True
        row["terminal_notified"] = True
        row["closed_at"] = _now()
        row["closed_by"] = closed_by

    notified += process_sentry_resolves(
        prs,
        mode=resolve_mode,
        min_age_hours=sentry_resolve_min_age_hours,
        max_age_days=sentry_resolve_max_age_days,
        skew_minutes=sentry_resolve_skew_minutes,
        profile=profile,
        repo_slug=repo_slug,
        webhook_url=webhook_url,
        bot_token=bot_token,
        channel_id=channel_id,
        notify=notify,
    )

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
    poll.add_argument(
        "--sentry-resolve-mode",
        default=os.environ.get("SENTRY_RESOLVE_AFTER_MERGE", "auto"),
    )
    poll.add_argument(
        "--sentry-resolve-min-age-hours",
        type=float,
        default=float(os.environ.get("SENTRY_RESOLVE_MIN_AGE_HOURS", "6")),
    )
    poll.add_argument(
        "--sentry-resolve-max-age-days",
        type=float,
        default=float(os.environ.get("SENTRY_RESOLVE_MAX_AGE_DAYS", "14")),
    )
    poll.add_argument(
        "--sentry-resolve-skew-minutes",
        type=int,
        default=int(os.environ.get("SENTRY_RESOLVE_SKEW_MINUTES", "5")),
    )

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
        sentry_resolve_mode=args.sentry_resolve_mode,
        sentry_resolve_min_age_hours=args.sentry_resolve_min_age_hours,
        sentry_resolve_max_age_days=args.sentry_resolve_max_age_days,
        sentry_resolve_skew_minutes=args.sentry_resolve_skew_minutes,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
