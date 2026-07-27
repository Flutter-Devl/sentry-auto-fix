#!/usr/bin/env python3
"""Build the ## Quality section for Bitbucket draft PR descriptions."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from codeguardian_summary import summarize_codeguardian_output


def load_env_file(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        data[key.strip()] = value.strip()
    return data


def build_quality_section(state_dir: Path) -> str:
    """Markdown checklist: Flutter tests + CodeGuardian from the latest gate run."""
    env = load_env_file(state_dir / "run-result.env")
    test_result = (env.get("TEST_RESULT") or "").strip() or "skipped (not required / not run)"
    test_command = (env.get("TEST_COMMAND") or "").strip() or "_(none)_"
    cg_status = (env.get("CODEGUARDIAN_STATUS") or "").strip() or "skipped"

    cg_detail_path = state_dir / "codeguardian-detail.txt"
    cg_summary = ""
    if cg_detail_path.exists():
        raw = cg_detail_path.read_text(encoding="utf-8", errors="replace")
        cg_summary = summarize_codeguardian_output(raw).strip()

    lines = [
        "## Quality",
        "",
        "Automated gates from this autofix cycle (reviewers: Slack is optional).",
        "",
        f"- **Tests:** `{test_result}`",
        f"  - Command: `{test_command}`",
        f"- **CodeGuardian:** `{cg_status}`",
    ]
    if cg_summary:
        lines.append("")
        lines.append("### CodeGuardian summary")
        lines.append("")
        lines.append("```")
        lines.append(cg_summary[:3500])
        lines.append("```")
    lines.append("")
    return "\n".join(lines)


def strip_existing_quality_section(text: str) -> str:
    """Remove a previous ## Quality block so we can re-append a fresh one."""
    if not text:
        return ""
    pattern = re.compile(r"(?ms)^## Quality\s*\n.*?(?=^## |\Z)")
    return pattern.sub("", text).strip()


def merge_quality_into_body(body: str, state_dir: Path) -> str:
    cleaned = strip_existing_quality_section(body).rstrip()
    quality = build_quality_section(state_dir).rstrip()
    return f"{cleaned}\n\n{quality}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Emit PR Quality markdown section")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument(
        "--merge-into",
        default="",
        help="Path to existing PR body markdown; prints body + Quality section",
    )
    args = parser.parse_args()
    state_dir = Path(args.state_dir)
    if args.merge_into:
        body = Path(args.merge_into).read_text(encoding="utf-8", errors="replace")
        sys.stdout.write(merge_quality_into_body(body, state_dir))
    else:
        sys.stdout.write(build_quality_section(state_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
