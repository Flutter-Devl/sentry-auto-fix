#!/usr/bin/env python3
"""Tests for CodeGuardian Slack summary formatting."""

from __future__ import annotations

import unittest

from codeguardian_summary import summarize_codeguardian_output


SAMPLE = r'''exit=0
{
  "passed": true,
  "findings": [
    {
      "ruleId": "duplicate-code-block",
      "category": "style",
      "severity": "low",
      "file": "/Users/mehsarairfan/sentry-auto-fix/.state/flutter/fix-worktree/packages/flutter_cached_pdfview/example/lib/main.dart",
      "line": 100,
      "message": "This 6-line block duplicates the code starting at line 80."
    },
    {
      "ruleId": "unused-plugin-dependency",
      "category": "performance",
      "severity": "low",
      "file": "/Users/mehsarairfan/sentry-auto-fix/.state/flutter/fix-worktree/pubspec.yaml",
      "line": 95,
      "message": "'animations' is declared as a dependency in pubspec.yaml but is never imported anywhere under lib/."
    }
  ]
}
'''

FRAGMENTED = '''exit=0
    {
      "category": "style",
      "severity": "low",
      "file": "/x/packages/foo/lib/main.dart",
      "line": 100,
      "message": "This 6-line block duplicates the code starting at line 80.",
      "ruleId": "duplicate-code-block"
    },
    {
      "ruleId": "unused-plugin-dependency",
      "category": "performance",
      "severity": "low",
      "file": "/x/pubspec.yaml",
      "line": 95,
      "message": "'animations' is unused."
    }
]
'''


class CodeGuardianSummaryTests(unittest.TestCase):
    def test_readable_summary(self) -> None:
        text = summarize_codeguardian_output(SAMPLE)
        self.assertIn("CodeGuardian PASSED", text)
        self.assertIn("Findings: 2", text)
        self.assertIn("duplicate-code-block", text)
        self.assertIn("unused-plugin-dependency", text)
        self.assertIn("packages/flutter_cached_pdfview", text)
        self.assertNotIn('"ruleId"', text)
        self.assertNotIn("snippet", text)

    def test_fragmented_tail_still_summarizes(self) -> None:
        text = summarize_codeguardian_output(FRAGMENTED)
        self.assertIn("CodeGuardian PASSED", text)
        self.assertIn("duplicate-code-block", text)
        self.assertIn("unused-plugin-dependency", text)

    def test_failed_exit(self) -> None:
        text = summarize_codeguardian_output('exit=1\n{"passed": false, "findings": []}')
        self.assertIn("FAILED", text)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
