#!/usr/bin/env python3
"""Tests for Sentry resolve-after-merge and PR Quality section."""

from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock

from pr_quality import build_quality_section, merge_quality_into_body, strip_existing_quality_section
from sentry_client import SentryIssue
from sentry_resolve import issue_is_quiet, maybe_resolve_after_merge


class QuietCheckTests(unittest.TestCase):
    def test_quiet_when_last_seen_before_merge(self) -> None:
        merged = datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc)
        self.assertTrue(
            issue_is_quiet(
                last_seen="2026-07-20T11:00:00Z",
                merged_at=merged,
                skew_minutes=5,
            )
        )

    def test_noisy_when_last_seen_after_merge(self) -> None:
        merged = datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc)
        self.assertFalse(
            issue_is_quiet(
                last_seen="2026-07-20T14:00:00Z",
                merged_at=merged,
                skew_minutes=5,
            )
        )


class ResolveAfterMergeTests(unittest.TestCase):
    def _client(self, *, status: str = "unresolved", last_seen: str = "2026-07-20T10:00:00Z"):
        client = MagicMock()
        client.find_issue_by_short_id.return_value = SentryIssue(
            id="123",
            short_id="ROBO-1",
            title="boom",
            permalink="https://example/sentry",
            last_seen=last_seen,
            culprit=None,
            metadata={},
        )
        client.get_issue.return_value = {
            "id": "123",
            "status": status,
            "lastSeen": last_seen,
        }
        return client

    def test_waits_for_min_age(self) -> None:
        client = self._client()
        merged = datetime.now(timezone.utc) - timedelta(hours=1)
        out = maybe_resolve_after_merge(
            client,
            short_id="ROBO-1",
            merged_at=merged,
            mode="auto",
            min_age_hours=6,
        )
        self.assertEqual(out.status, "waiting")
        client.resolve_issue.assert_not_called()

    def test_auto_resolves_when_quiet(self) -> None:
        client = self._client(last_seen="2026-07-20T10:00:00Z")
        merged = datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc)
        now = merged + timedelta(hours=7)
        out = maybe_resolve_after_merge(
            client,
            short_id="ROBO-1",
            merged_at=merged,
            mode="auto",
            min_age_hours=6,
            now=now,
        )
        self.assertEqual(out.status, "resolved")
        self.assertEqual(out.notify_event, "sentry_resolved")
        client.resolve_issue.assert_called_once_with("123")

    def test_prompt_mode_does_not_resolve(self) -> None:
        client = self._client(last_seen="2026-07-20T10:00:00Z")
        merged = datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc)
        now = merged + timedelta(hours=7)
        out = maybe_resolve_after_merge(
            client,
            short_id="ROBO-1",
            merged_at=merged,
            mode="prompt",
            min_age_hours=6,
            now=now,
        )
        self.assertEqual(out.status, "prompted")
        self.assertEqual(out.notify_event, "sentry_resolve_ready")
        client.resolve_issue.assert_not_called()

    def test_noisy_notifies_once(self) -> None:
        client = self._client(last_seen="2026-07-21T15:00:00Z")
        merged = datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc)
        now = merged + timedelta(hours=7)
        out = maybe_resolve_after_merge(
            client,
            short_id="ROBO-1",
            merged_at=merged,
            mode="auto",
            min_age_hours=6,
            now=now,
            already_noisy_notified=False,
        )
        self.assertEqual(out.status, "noisy")
        self.assertEqual(out.notify_event, "sentry_still_noisy")
        client.resolve_issue.assert_not_called()


class PrQualityTests(unittest.TestCase):
    def test_builds_quality_section(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "run-result.env").write_text(
                "TEST_RESULT=PASSED\nTEST_COMMAND=flutter test\nCODEGUARDIAN_STATUS=passed\n",
                encoding="utf-8",
            )
            (state / "codeguardian-detail.txt").write_text(
                'exit=0\n{"passed": true, "findings": []}\n',
                encoding="utf-8",
            )
            text = build_quality_section(state)
            self.assertIn("## Quality", text)
            self.assertIn("PASSED", text)
            self.assertIn("flutter test", text)
            self.assertIn("CodeGuardian", text)
            self.assertIn("passed", text)

    def test_merge_replaces_old_quality(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            (state / "run-result.env").write_text(
                "TEST_RESULT=PASSED\nCODEGUARDIAN_STATUS=passed\n",
                encoding="utf-8",
            )
            body = "## Fix Strategy\n- ok\n\n## Quality\n\nold stuff\n\n## After merge\n- x\n"
            merged = merge_quality_into_body(body, state)
            self.assertEqual(merged.count("## Quality"), 1)
            self.assertNotIn("old stuff", merged)
            self.assertIn("## Fix Strategy", merged)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
