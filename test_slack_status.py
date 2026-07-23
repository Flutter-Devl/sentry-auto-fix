#!/usr/bin/env python3
"""Unit tests for Slack message builders and PR tracker state."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from pr_tracker import load_tracked, track_pr
from slack_notify import build_run_outcome_message


class SlackMessageTests(unittest.TestCase):
    def test_codeguardian_failed_includes_detail(self) -> None:
        text, blocks = build_run_outcome_message(
            profile="flutter",
            event="codeguardian_failed",
            issue_short_id="ROBO-1",
            issue_tier="tier1",
            branch="fix/sentry-robo-1",
            gate_reason="codeguardian",
            cg_status="failed",
            detail="exit=1 finding: missing-mounted-check",
        )
        body = blocks[0]["text"]["text"]
        self.assertIn("CodeGuardian failed", body)
        self.assertIn("ROBO-1", body)
        self.assertIn("missing-mounted-check", body)
        self.assertIn("codeguardian", text.lower() + body.lower())

    def test_pr_merged_message(self) -> None:
        text, blocks = build_run_outcome_message(
            profile="flutter",
            event="pr_merged",
            issue_short_id="ROBO-2",
            pr_url="https://bitbucket.org/ws/repo/pull-requests/9",
            title="fix(sentry): ROBO-2",
            detail="Merged by: Alice | Merge commit: `abc123`",
        )
        body = blocks[0]["text"]["text"]
        self.assertIn("PR merged", body)
        self.assertIn("Open pull request", body)
        self.assertIn("Alice", body)
        self.assertIn("ROBO-2", text)


class PrTrackerTests(unittest.TestCase):
    def test_track_and_dedupe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            track_pr(
                state,
                pr_id=42,
                pr_url="https://example/pr/42",
                branch="fix/sentry-x",
                issue_short_id="X-1",
            )
            track_pr(
                state,
                pr_id=42,
                pr_url="https://example/pr/42-updated",
                branch="fix/sentry-x",
                issue_short_id="X-1",
            )
            rows = load_tracked(state)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["pr_url"], "https://example/pr/42-updated")
            self.assertFalse(rows[0]["merged_notified"])

    def test_poll_merged_notifies_once(self) -> None:
        from pr_tracker import poll_merged

        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            track_pr(
                state,
                pr_id=7,
                pr_url="https://example/pr/7",
                branch="fix/sentry-y",
                issue_short_id="Y-1",
            )
            fake_pr = {
                "state": "MERGED",
                "title": "fix(sentry): Y-1",
                "links": {"html": {"href": "https://example/pr/7"}},
                "source": {"branch": {"name": "fix/sentry-y"}},
                "closed_by": {"display_name": "Bob"},
                "merge_commit": {"hash": "deadbeefcafebabe"},
            }
            with patch("pr_tracker.fetch_pr", return_value=fake_pr), patch(
                "pr_tracker.notify_run_outcome"
            ) as notify:
                n = poll_merged(
                    state,
                    workspace="ws",
                    repo_slug="repo",
                    access_token="token",
                    bot_token="xoxb-test",
                    channel_id="C123",
                    profile="flutter",
                )
                self.assertEqual(n, 1)
                self.assertEqual(notify.call_args.kwargs["event"], "pr_merged")
                n2 = poll_merged(
                    state,
                    workspace="ws",
                    repo_slug="repo",
                    access_token="token",
                    bot_token="xoxb-test",
                    channel_id="C123",
                    profile="flutter",
                )
                self.assertEqual(n2, 0)
                self.assertEqual(notify.call_count, 1)

    def test_poll_declined_includes_rejection_reason(self) -> None:
        from pr_tracker import poll_merged

        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            track_pr(
                state,
                pr_id=8,
                pr_url="https://example/pr/8",
                branch="fix/sentry-z",
                issue_short_id="Z-1",
            )
            fake_pr = {
                "state": "DECLINED",
                "title": "fix(sentry): Z-1",
                "links": {"html": {"href": "https://example/pr/8"}},
                "source": {"branch": {"name": "fix/sentry-z"}},
                "closed_by": {"display_name": "Carol"},
            }
            with patch("pr_tracker.fetch_pr", return_value=fake_pr), patch(
                "pr_tracker.extract_rejection_reason",
                return_value="Reject: lifecycle fix incomplete, need mounted check",
            ), patch("pr_tracker.notify_run_outcome") as notify, patch(
                "rejection_lessons.record_lesson"
            ):
                n = poll_merged(
                    state,
                    workspace="ws",
                    repo_slug="repo",
                    access_token="token",
                    bot_token="xoxb-test",
                    channel_id="C123",
                    profile="flutter",
                )
                self.assertEqual(n, 1)
                self.assertEqual(notify.call_args.kwargs["event"], "pr_declined")
                detail = notify.call_args.kwargs["detail"]
                self.assertIn("Rejection reason:", detail)
                self.assertIn("lifecycle fix incomplete", detail)

    def test_extract_rejection_reason_prefers_reviewer_comment(self) -> None:
        from pr_tracker import extract_rejection_reason

        comments = [
            {
                "content": {
                    "raw": "Reject: beforeSend is not acceptable, fix root cause"
                }
            },
            {"content": {"raw": "Automated Sentry fix.\n\n**Issue:** Z-1"}},
        ]
        with patch("pr_tracker.fetch_pr_comments", return_value=comments), patch(
            "pr_tracker.fetch_pr_activity", return_value=[]
        ):
            reason = extract_rejection_reason(
                session=object(),  # type: ignore[arg-type]
                workspace="ws",
                repo_slug="repo",
                pr_id=1,
                pr_data={"title": "fix(sentry): Z-1"},
            )
        self.assertIn("beforeSend is not acceptable", reason)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
