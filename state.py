"""Persistent state so we do not open duplicate PRs for the same issue."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


@dataclass
class IssueRecord:
    issue_id: str
    short_id: str
    title: str
    status: str  # success | failed | no_changes | skipped
    branch: str | None
    pr_url: str | None
    processed_at: str
    last_seen: str | None = None
    error: str | None = None


class StateStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._data: dict[str, Any] = {"processed": {}}
        if path.exists():
            self._data = json.loads(path.read_text(encoding="utf-8"))

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(self._data, indent=2), encoding="utf-8")

    def get(self, issue_id: str) -> IssueRecord | None:
        raw = self._data.get("processed", {}).get(issue_id)
        if not raw:
            return None
        return IssueRecord(**raw)

    def should_process(self, issue_id: str, last_seen: str | None) -> bool:
        record = self.get(issue_id)
        if record is None:
            return True
        if record.status in ("failed", "no_changes"):
            return True
        if record.status == "success" and last_seen and record.last_seen:
            return last_seen > record.last_seen
        return record.status != "success"

    def put(self, record: IssueRecord) -> None:
        self._data.setdefault("processed", {})[record.issue_id] = asdict(record)
        self.save()


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()
