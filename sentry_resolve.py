#!/usr/bin/env python3
"""Resolve Sentry issues after autofix PRs merge and events go quiet."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any

from sentry_client import SentryClient


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def issue_is_quiet(
    *,
    last_seen: str | None,
    merged_at: datetime,
    skew_minutes: int = 5,
) -> bool:
    """
    True when no events arrived after merge (with a small clock skew).

    lastSeen <= merged_at + skew ⇒ treat as quiet (deploy lag / clock drift).
    """
    seen = parse_iso(last_seen)
    if seen is None:
        # No lastSeen — treat as quiet only after merge time has passed
        return True
    return seen <= merged_at + timedelta(minutes=max(0, skew_minutes))


@dataclass
class ResolveOutcome:
    status: str  # resolved | already_resolved | waiting | prompted | noisy | skipped | failed
    detail: str = ""
    issue_id: str = ""
    last_seen: str = ""
    notify_event: str = ""  # slack event name, or empty


def maybe_resolve_after_merge(
    client: SentryClient,
    *,
    short_id: str,
    merged_at: datetime,
    mode: str = "auto",
    min_age_hours: float = 6.0,
    max_age_days: float = 14.0,
    skew_minutes: int = 5,
    already_prompted: bool = False,
    already_noisy_notified: bool = False,
    now: datetime | None = None,
) -> ResolveOutcome:
    """
    Decide whether to resolve / prompt / wait for a merged autofix.

    mode:
      - auto: resolve when quiet after min_age
      - prompt: Slack when quiet; never auto-resolve
      - off: skip
    """
    mode = (mode or "auto").strip().lower()
    if mode in ("off", "false", "0", "no"):
        return ResolveOutcome(status="skipped", detail="SENTRY_RESOLVE_AFTER_MERGE=off")

    if not short_id or short_id.upper() in ("NONE", "UNKNOWN", "N/A"):
        return ResolveOutcome(status="skipped", detail="No ISSUE_SHORT_ID on tracked PR")

    now = now or datetime.now(timezone.utc)
    age = now - merged_at
    if age < timedelta(hours=max(0.0, min_age_hours)):
        hours_left = max(0.0, min_age_hours) - age.total_seconds() / 3600.0
        return ResolveOutcome(
            status="waiting",
            detail=f"Waiting for min age ({hours_left:.1f}h left before quiet check)",
        )

    if age > timedelta(days=max(0.1, max_age_days)):
        return ResolveOutcome(
            status="abandoned",
            detail=f"Gave up after {max_age_days}d — issue still unresolved or noisy",
            notify_event="sentry_resolve_abandoned",
        )

    found = client.find_issue_by_short_id(short_id)
    if found is None:
        return ResolveOutcome(
            status="failed",
            detail=f"Could not find Sentry issue for {short_id}",
            notify_event="sentry_resolve_failed",
        )

    issue_id = found.id
    try:
        payload = client.get_issue(issue_id)
    except Exception as exc:  # noqa: BLE001
        return ResolveOutcome(
            status="failed",
            detail=f"Sentry get_issue failed: {exc}",
            issue_id=issue_id,
            notify_event="sentry_resolve_failed",
        )

    status = str(payload.get("status") or "").lower()
    last_seen = str(payload.get("lastSeen") or found.last_seen or "")
    if status == "resolved":
        return ResolveOutcome(
            status="already_resolved",
            detail="Issue already resolved in Sentry",
            issue_id=issue_id,
            last_seen=last_seen,
        )

    quiet = issue_is_quiet(
        last_seen=last_seen, merged_at=merged_at, skew_minutes=skew_minutes
    )

    if not quiet:
        event = ""
        if not already_noisy_notified:
            event = "sentry_still_noisy"
        return ResolveOutcome(
            status="noisy",
            detail=(
                f"Still receiving events after merge "
                f"(lastSeen={last_seen or 'unknown'}; merged_at={merged_at.isoformat()})"
            ),
            issue_id=issue_id,
            last_seen=last_seen,
            notify_event=event,
        )

    if mode == "prompt":
        event = "" if already_prompted else "sentry_resolve_ready"
        return ResolveOutcome(
            status="prompted",
            detail=(
                f"Events quiet since merge. Resolve manually: "
                f"./run.sh resolve-issue {short_id}"
            ),
            issue_id=issue_id,
            last_seen=last_seen,
            notify_event=event,
        )

    # auto
    try:
        client.resolve_issue(issue_id)
    except Exception as exc:  # noqa: BLE001
        return ResolveOutcome(
            status="failed",
            detail=f"Sentry resolve failed: {exc}",
            issue_id=issue_id,
            last_seen=last_seen,
            notify_event="sentry_resolve_failed",
        )

    return ResolveOutcome(
        status="resolved",
        detail=f"Auto-resolved {short_id} (issue id {issue_id}); lastSeen={last_seen or 'n/a'}",
        issue_id=issue_id,
        last_seen=last_seen,
        notify_event="sentry_resolved",
    )


def apply_outcome_to_row(row: dict[str, Any], outcome: ResolveOutcome) -> None:
    row["sentry_resolve_status"] = outcome.status
    row["sentry_resolve_detail"] = outcome.detail
    row["sentry_resolve_checked_at"] = datetime.now(timezone.utc).isoformat()
    if outcome.issue_id:
        row["sentry_issue_id"] = outcome.issue_id
    if outcome.last_seen:
        row["sentry_last_seen"] = outcome.last_seen
    if outcome.status == "prompted":
        row["sentry_resolve_prompted"] = True
    if outcome.status == "noisy" and outcome.notify_event:
        row["sentry_noisy_notified"] = True
    if outcome.status in ("resolved", "already_resolved"):
        row["sentry_resolved_at"] = datetime.now(timezone.utc).isoformat()
