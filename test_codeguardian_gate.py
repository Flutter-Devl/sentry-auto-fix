#!/usr/bin/env python3
"""Unit tests for codeguardian_gate (no live Dart required)."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from codeguardian_gate import run_codeguardian


class CodeGuardianGateTests(unittest.TestCase):
    def test_builds_dart_run_command(self) -> None:
        mock = MagicMock(returncode=0, stdout='{"pass":true}', stderr="")
        with patch("subprocess.run", return_value=mock) as run:
            ok, detail = run_codeguardian(
                worktree=Path("/tmp/wt"),
                cli="dart run /opt/cg/packages/codeguardian_cli/bin/codeguardian.dart",
                mode="validate",
                timeout=30,
            )
        self.assertTrue(ok)
        self.assertIn("exit=0", detail)
        self.assertEqual(
            run.call_args[0][0],
            [
                "dart",
                "run",
                "/opt/cg/packages/codeguardian_cli/bin/codeguardian.dart",
                "validate",
                "-p",
                "/tmp/wt",
            ],
        )

    def test_wrapper_script_command(self) -> None:
        mock = MagicMock(returncode=0, stdout="{}", stderr="")
        with patch("subprocess.run", return_value=mock) as run:
            ok, _ = run_codeguardian(
                worktree=Path("/tmp/wt"),
                cli="/opt/cg/run-codeguardian.sh",
                mode="validate",
            )
        self.assertTrue(ok)
        self.assertEqual(
            run.call_args[0][0],
            ["/opt/cg/run-codeguardian.sh", "validate", "-p", "/tmp/wt"],
        )

    def test_gate_failure_is_not_ok(self) -> None:
        mock = MagicMock(returncode=1, stdout="gate failed", stderr="")
        with patch("subprocess.run", return_value=mock):
            ok, detail = run_codeguardian(
                worktree=Path("/tmp/wt"),
                cli="/bin/codeguardian",
                mode="validate",
            )
        self.assertFalse(ok)
        self.assertIn("exit=1", detail)

    def test_tool_error_is_not_ok(self) -> None:
        mock = MagicMock(returncode=2, stdout="", stderr="analyzer crash")
        with patch("subprocess.run", return_value=mock):
            ok, detail = run_codeguardian(
                worktree=Path("/tmp/wt"),
                cli="/bin/codeguardian",
                mode="analyze",
            )
        self.assertFalse(ok)
        self.assertIn("exit=2", detail)

    def test_empty_cli(self) -> None:
        ok, detail = run_codeguardian(
            worktree=Path("/tmp/wt"), cli="  ", mode="validate"
        )
        self.assertFalse(ok)
        self.assertIn("empty", detail)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
