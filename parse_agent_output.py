#!/usr/bin/env python3
"""Parse Cursor agent stream-json / plain output for sentry-auto-fix run.sh."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

FIELDS = (
    "ISSUE_SHORT_ID",
    "ISSUE_TIER",
    "ISSUE_URL",
    "BRANCH_NAME",
    "SEARCHED_ISSUES",
    "FIX_CONFIDENCE",
    "FIX_STRATEGY",
    "TEST_COMMAND",
    "TEST_RESULT",
)


def _field_pattern(field: str) -> re.Pattern[str]:
    return re.compile(rf"(?:^|\n){re.escape(field)}=([^\n`]+)")


def ingest_text(text: str, found: dict[str, str], no_action: bool) -> bool:
    if re.search(r"(?:^|\n)NO_ACTION\s*(?:\n|$)", text.strip()):
        no_action = True
    for field in FIELDS:
        match = _field_pattern(field).search(text)
        if match:
            found[field] = match.group(1).strip().strip("`")
    return no_action


def parse_log(path: Path) -> tuple[dict[str, str], bool]:
    found = {field: "" for field in FIELDS}
    no_action = False

    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return found, no_action

    for line in content.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("type") == "result" and isinstance(obj.get("result"), str):
            no_action = ingest_text(obj["result"], found, no_action)
            continue
        if obj.get("type") != "assistant":
            continue
        msg = obj.get("message") or {}
        for part in msg.get("content") or []:
            if part.get("type") == "text" and isinstance(part.get("text"), str):
                no_action = ingest_text(part["text"], found, no_action)

    no_action = ingest_text(content, found, no_action)
    if found["BRANCH_NAME"]:
        no_action = False
    return found, no_action


def parse_field(path: Path, field: str) -> str:
    found, _ = parse_log(path)
    return found.get(field, "")


def write_env(path: Path, out_path: Path) -> None:
    found, no_action = parse_log(path)
    lines = [f"{field}={found[field]}" for field in FIELDS if found[field]]
    lines.append(
        f"NO_ACTION={'true' if no_action and not found['BRANCH_NAME'] else 'false'}"
    )
    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: parse_agent_output.py field <last-run.log>", file=sys.stderr)
        print("       parse_agent_output.py env <last-run.log> <run-result.env>", file=sys.stderr)
        return 2

    mode = sys.argv[1]
    log_path = Path(sys.argv[2])

    if mode == "field":
        if len(sys.argv) != 4:
            print("usage: parse_agent_output.py field <last-run.log> <FIELD>", file=sys.stderr)
            return 2
        print(parse_field(log_path, sys.argv[3]))
        return 0

    if mode == "env":
        if len(sys.argv) != 4:
            print("usage: parse_agent_output.py env <last-run.log> <run-result.env>", file=sys.stderr)
            return 2
        write_env(log_path, Path(sys.argv[3]))
        return 0

    print(f"unknown mode: {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
