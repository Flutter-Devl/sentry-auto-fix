#!/usr/bin/env python3
"""Tests for agent output parsing (BRANCH_NAME / NO_ACTION)."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from parse_agent_output import parse_log, write_env


def _assistant_line(text: str) -> str:
    return json.dumps(
        {
            "type": "assistant",
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": text}],
            },
        }
    )


class ParseAgentOutputTests(unittest.TestCase):
    def test_no_action_with_none_placeholders_is_no_action(self) -> None:
        text = """PHASE: done

**NO_ACTION**

All candidates exhausted.

ISSUE_SHORT_ID=NONE
ISSUE_TIER=none
ISSUE_URL=none
BRANCH_NAME=none
FIX_CONFIDENCE=none
TEST_RESULT=none
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "last-run.log"
            path.write_text(_assistant_line(text) + "\n", encoding="utf-8")
            found, no_action = parse_log(path)
            self.assertTrue(no_action)
            self.assertEqual(found["BRANCH_NAME"], "")
            self.assertEqual(found["ISSUE_SHORT_ID"], "")

            out = Path(tmp) / "run-result.env"
            write_env(path, out)
            env = out.read_text(encoding="utf-8")
            self.assertIn("NO_ACTION=true", env)
            self.assertNotIn("BRANCH_NAME=", env)

    def test_real_branch_clears_no_action(self) -> None:
        text = """PHASE: done
ISSUE_SHORT_ID=ROBO-STAGING-EN
BRANCH_NAME=fix/sentry-robo-staging-en-future-already-completed
TEST_RESULT=PASSED
"""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "last-run.log"
            path.write_text(_assistant_line(text) + "\n", encoding="utf-8")
            found, no_action = parse_log(path)
            self.assertFalse(no_action)
            self.assertTrue(found["BRANCH_NAME"].startswith("fix/sentry-"))


if __name__ == "__main__":
    raise SystemExit(unittest.main())
