#!/usr/bin/env python3
"""Summarize CodeGuardian JSON output for humans (Slack / logs)."""

from __future__ import annotations

import json
import re
from collections import Counter
from pathlib import Path


def _short_path(path: str) -> str:
    path = path.replace("\\", "/")
    # Prefer package-relative paths so Slack shows which package was flagged
    for marker in ("/packages/", "/fix-worktree/", "/lib/", "/test/"):
        idx = path.find(marker)
        if idx >= 0:
            # For /packages/, keep "packages/..."
            if marker == "/packages/":
                return path[idx + 1 :]
            if marker == "/fix-worktree/":
                rest = path[idx + len(marker) :]
                return rest
            return path[idx + 1 :]
    return Path(path).name


def summarize_codeguardian_output(raw: str, *, max_findings: int = 8) -> str:
    """
    Turn raw CG CLI output (often exit=N + JSON) into a short readable summary.

    Example:
      CodeGuardian PASSED (exit 0)
      Findings: 12 (style:9, performance:3) — gates still passed
      Top:
      - [low/style] duplicate-code-block — packages/.../main.dart:100
      - [low/performance] unused-plugin-dependency — pubspec.yaml:95
    """
    text = (raw or "").strip()
    if not text:
        return "CodeGuardian: no output"

    exit_m = re.search(r"exit\s*=\s*(\d+)", text, re.I)
    exit_code = exit_m.group(1) if exit_m else "?"

    # Prefer last JSON object in the blob
    findings: list[dict] = []
    gate_ok: bool | None = None
    json_blob = ""
    # Find outermost { ... } that looks like CG JSON
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        json_blob = text[start : end + 1]
        try:
            data = json.loads(json_blob)
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict):
            if "findings" in data and isinstance(data["findings"], list):
                findings = [f for f in data["findings"] if isinstance(f, dict)]
            elif "results" in data and isinstance(data["results"], list):
                findings = [f for f in data["results"] if isinstance(f, dict)]
            # Some payloads are {"findings":[...]} nested under report
            report = data.get("report")
            if not findings and isinstance(report, dict) and isinstance(
                report.get("findings"), list
            ):
                findings = [f for f in report["findings"] if isinstance(f, dict)]
            if "passed" in data:
                gate_ok = bool(data["passed"])
            elif "ok" in data:
                gate_ok = bool(data["ok"])

    # Fallback: array-only payload
    if not findings:
        arr_start = text.find("[")
        arr_end = text.rfind("]")
        if arr_start >= 0 and arr_end > arr_start:
            try:
                arr = json.loads(text[arr_start : arr_end + 1])
                if isinstance(arr, list):
                    findings = [f for f in arr if isinstance(f, dict)]
            except json.JSONDecodeError:
                pass

    status = "PASSED" if exit_code == "0" else "FAILED"
    if gate_ok is True:
        status = "PASSED"
    elif gate_ok is False:
        status = "FAILED"

    lines = [f"CodeGuardian {status} (exit {exit_code})"]

    if not findings:
        # No structured findings — keep a tiny plain snippet
        plain = re.sub(r"\s+", " ", text)
        if len(plain) > 220:
            plain = plain[:220] + "…"
        lines.append(plain)
        return "\n".join(lines)

    by_sev = Counter((f.get("severity") or "unknown").lower() for f in findings)
    by_cat = Counter((f.get("category") or "unknown").lower() for f in findings)
    sev_bits = ", ".join(f"{k}:{v}" for k, v in sorted(by_sev.items()))
    cat_bits = ", ".join(f"{k}:{v}" for k, v in sorted(by_cat.items()))
    lines.append(f"Findings: {len(findings)} ({sev_bits})")
    if cat_bits:
        lines.append(f"Categories: {cat_bits}")
    if status == "PASSED" and findings:
        lines.append("Note: findings are informational — quality gate still passed")

    # Show highest severity first
    sev_rank = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4, "unknown": 5}
    ordered = sorted(
        findings,
        key=lambda f: sev_rank.get(str(f.get("severity", "unknown")).lower(), 5),
    )

    lines.append("Top findings:")
    for finding in ordered[:max_findings]:
        rule = finding.get("ruleId") or finding.get("rule") or "rule"
        sev = finding.get("severity") or "?"
        cat = finding.get("category") or "?"
        msg = (finding.get("message") or "").strip()
        if len(msg) > 120:
            msg = msg[:117] + "…"
        file_path = _short_path(str(finding.get("file") or ""))
        line_no = finding.get("line")
        loc = f"{file_path}:{line_no}" if file_path and line_no else file_path or ""
        prefix = f"- [{sev}/{cat}] {rule}"
        if loc:
            prefix += f" @ {loc}"
        if msg:
            prefix += f" — {msg}"
        lines.append(prefix)

    remaining = len(ordered) - max_findings
    if remaining > 0:
        lines.append(f"…and {remaining} more")

    return "\n".join(lines)


def summarize_file(path: Path, *, max_findings: int = 8) -> str:
    if not path.exists():
        return "CodeGuardian: detail file missing"
    return summarize_codeguardian_output(
        path.read_text(encoding="utf-8", errors="replace"),
        max_findings=max_findings,
    )


if __name__ == "__main__":
    import sys

    raw = Path(sys.argv[1]).read_text(encoding="utf-8") if len(sys.argv) > 1 else sys.stdin.read()
    print(summarize_codeguardian_output(raw))
