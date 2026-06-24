#!/usr/bin/env python3
"""Sentry issue pagination + skip rules for sentry-auto-fix."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import TYPE_CHECKING, Any, Iterable
from urllib.parse import parse_qs, urlparse

if TYPE_CHECKING:
    from sentry_client import SentryIssue

LAUNCHDARKLY_MARKERS = (
    "launchdarkly",
    "launch_darkly",
    "launch darkly",
    "launchdarkly_provider",
    "launch-darkly",
)

# ---------------------------------------------------------------------------
# Flutter / Dart triage tiers
# ---------------------------------------------------------------------------

# tier1 — fix first (app bugs in lib/)
FLUTTER_TIER1_MARKERS = (
    "typeerror",
    "type error",
    "is not a subtype",
    "type cast",
    "cast from",
    "go_router",
    "gorouter",
    "gorouterdelegate",
    "routeinformationparser",
    "navigation",
    "stateerror",
    "bad state",
    "setstate",
    "state notifier",
    "null check",
    "unexpectedly found null",
    "nosuchmethoderror",
    "null value",
    "unauthorized",
    "unauthorised",
    "401",
    "403 forbidden",
    "authentication failed",
    "platformexception",
    "platform exception",
)

# tier1 — targeted Sentry searches (always run fresh before tier3 pagination)
FLUTTER_TIER1_SEARCH_QUERIES = (
    "TypeError",
    "PlatformException",
    "StateError",
    "GoRouter",
    "GoError",
    "go_router",
    "Null check",
    "unauthorized",
    "UnauthorizedException"
    "DioException"
    "401",
    "RangeError",
    "FormatException",
    "ArgumentError",
    "NoInternetConnectionException"
)

# tier2 — general app issues in lib/
FLUTTER_TIER2_SEARCH_QUERIES = (
    "Riverpod",
    "Provider",
    "AsyncError",
    "JsonUnsupportedObjectError",
)

# tier3 — last resort (vendor / native noise) — only when tier1/2 exhausted
FLUTTER_TIER3_MARKERS = (
    *LAUNCHDARKLY_MARKERS,
    "apphang",
    "app hang",
    "app hanging",
    "applicationnotresponding",
    "anr",
    "watchdogtermination",
    "watchdog termination",
    "pasteboard",
    "uipasteboard",
    "pbserverconnection",
    "httpclienterror",
    "adjust",
    "iterable",
    "firebase",
    "native crash",
)

# ---------------------------------------------------------------------------
# Laravel / PHP triage tiers
# ---------------------------------------------------------------------------

# tier1 — critical database, auth, and runtime PHP errors (fix first)
LARAVEL_TIER1_MARKERS = (
    "queryexception",
    "pdoexception",
    "modelnotfoundexception",
    "authorizationexception",
    "authenticationexception",
    "unauthenticated",
    "unauthorized",
    "401",
    "403",
    "validationexception",
    "typeerror",
    "null value",
    "call to a member function",
    "trying to get property",
    "undefined variable",
    "undefined index",
    "undefined array key",
    "errorexception",
    "badmethodcallexception",
    "invalidargumentexception",
    "runtimeexception",
    "notfoundhttpexception",
)

LARAVEL_TIER1_SEARCH_QUERIES = (
    "QueryException",
    "ModelNotFoundException",
    "AuthorizationException",
    "AuthenticationException",
    "ValidationException",
    "PDOException",
    "Unauthenticated",
    "TypeError",
    "ErrorException",
    "BadMethodCallException",
    "NotFoundHttpException",
)

# tier2 — queue, HTTP client, mail, and general framework errors (targeted Sentry searches)
LARAVEL_TIER2_SEARCH_QUERIES = (
    "HttpException",
    "ConnectionException",
    "SocketException",
    "TimeoutException",
    "Job",
    "Queue",
    "CommandException",
)

# tier3 — last resort: vendor/package noise, Horizon, Telescope, Debugbar
LARAVEL_TIER3_MARKERS = (
    "vendor/",
    "horizon",
    "telescope",
    "debugbar",
    "clockwork",
    "sentry\\laravel",
    "barryvdh",
    "native crash",
    "apphang",
)

# ---------------------------------------------------------------------------
# Backward-compat aliases (used in existing call sites below)
# ---------------------------------------------------------------------------
TIER1_MARKERS = FLUTTER_TIER1_MARKERS
TIER1_SEARCH_QUERIES = FLUTTER_TIER1_SEARCH_QUERIES
TIER2_SEARCH_QUERIES = FLUTTER_TIER2_SEARCH_QUERIES
TIER3_MARKERS = FLUTTER_TIER3_MARKERS


def issue_haystack(issue: Any) -> str:
    return " ".join(
        filter(
            None,
            [
                issue.title,
                issue.culprit or "",
                issue.short_id,
                str(issue.metadata),
            ],
        )
    ).lower()


def is_launchdarkly_issue(issue: Any) -> bool:
    haystack = issue_haystack(issue)
    return any(marker in haystack for marker in LAUNCHDARKLY_MARKERS)


def is_vendor_noise_issue(issue: Any) -> bool:
    haystack = issue_haystack(issue)
    return any(marker in haystack for marker in TIER3_MARKERS)


def classify_issue_tier(issue: Any) -> int:
    """Return 1 (app bugs first), 2 (general app code), or 3 (vendor/native last).

    Tier selection is profile-aware: PROJECT_PROFILE env var switches between
    Flutter (default) and Laravel marker/path sets.
    """
    haystack = issue_haystack(issue)
    profile = os.environ.get("PROJECT_PROFILE", "flutter").lower()

    if profile == "laravel":
        if any(marker in haystack for marker in LARAVEL_TIER1_MARKERS):
            return 1
        if any(marker in haystack for marker in LARAVEL_TIER3_MARKERS):
            return 3
        if "app/" in haystack or "routes/" in haystack:
            return 2
        if "vendor/" in haystack:
            return 3
        return 2
    else:
        # Flutter / default
        if any(marker in haystack for marker in FLUTTER_TIER1_MARKERS):
            return 1
        if any(marker in haystack for marker in FLUTTER_TIER3_MARKERS):
            return 3
        if "lib/" in haystack:
            return 2
        if any(
            marker in haystack
            for marker in ("ios/", "android/", "uikit", "java.", "objc", "swift")
        ):
            return 3
        return 2

STATE_FILE = "sentry-pagination.json"
CANDIDATES_FILE = "sentry-candidates.json"
CONTEXT_FILE = "sentry-search-context.txt"


def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        os.environ.setdefault(key.strip(), value)


@dataclass
class PaginationState:
    excluded_short_ids: list[str]
    api_cursor: str | None = None
    pages_fetched: int = 0

    @classmethod
    def load(cls, path: Path) -> PaginationState:
        if not path.exists():
            return cls(excluded_short_ids=[])
        raw = json.loads(path.read_text(encoding="utf-8"))
        return cls(
            excluded_short_ids=list(raw.get("excluded_short_ids") or []),
            api_cursor=raw.get("api_cursor"),
            pages_fetched=int(raw.get("pages_fetched") or 0),
        )

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2) + "\n", encoding="utf-8")


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.lower() in ("1", "true", "yes", "on")


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    return int(raw) if raw else default


def branch_to_short_id(branch: str, project_slug: str) -> str | None:
    prefix = "fix/sentry-"
    if not branch.startswith(prefix):
        return None
    rest = branch[len(prefix) :]
    project = project_slug.lower()
    if not rest.startswith(f"{project}-"):
        return None
    suffix = rest[len(project) + 1 :]
    key = suffix.split("-", 1)[0]
    if not key:
        return None
    return f"{project_slug.upper()}-{key.upper()}"


def list_branched_short_ids(repo_root: Path, project_slug: str) -> set[str]:
    short_ids: set[str] = set()
    try:
        proc = subprocess.run(
            ["git", "ls-remote", "--heads", "origin", "fix/sentry-*"],
            cwd=repo_root,
            text=True,
            capture_output=True,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        return short_ids

    if proc.returncode != 0:
        return short_ids

    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        ref = parts[1]
        branch = ref.removeprefix("refs/heads/")
        short_id = branch_to_short_id(branch, project_slug)
        if short_id:
            short_ids.add(short_id)
    return short_ids


def issue_to_candidate(issue: Any, tier: int) -> dict[str, Any]:
    return {
        "short_id": issue.short_id,
        "title": issue.title,
        "permalink": issue.permalink,
        "id": issue.id,
        "tier": f"tier{tier}",
    }


def dedupe_issues(issues: list[Any]) -> list[Any]:
    seen: set[str] = set()
    unique: list[Any] = []
    for issue in issues:
        if issue.short_id in seen:
            continue
        seen.add(issue.short_id)
        unique.append(issue)
    return unique


def search_issues(
    client: Any,
    *,
    search_term: str,
    page_size: int,
    branched: set[str],
    excluded: set[str],
    required_tier: int | None = None,
) -> list[Any]:
    query = f"is:unresolved {search_term}".strip()
    found: list[Any] = []
    for page, _link in client.iter_unresolved_issue_pages(
        query=query,
        limit=page_size,
        cursor=None,
        max_pages=1,
    ):
        for issue in page:
            if should_skip_issue(issue, branched=branched, excluded=excluded):
                continue
            tier = classify_issue_tier(issue)
            if required_tier is not None and tier != required_tier:
                continue
            found.append(issue)
    return dedupe_issues(found)


def _get_tier_search_queries() -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Return (tier1_queries, tier2_queries) for the active PROJECT_PROFILE."""
    profile = os.environ.get("PROJECT_PROFILE", "flutter").lower()
    if profile == "laravel":
        return LARAVEL_TIER1_SEARCH_QUERIES, LARAVEL_TIER2_SEARCH_QUERIES
    return FLUTTER_TIER1_SEARCH_QUERIES, FLUTTER_TIER2_SEARCH_QUERIES


def fetch_candidates_by_tier_priority(
    client: Any,
    *,
    base_query: str,
    page_size: int,
    max_pages: int,
    branched: set[str],
    excluded: set[str],
    triage_simple_first: bool,
    start_cursor: str | None,
) -> tuple[list[dict[str, Any]], int | None, list[Any], str | None, int]:
    """Tier1/2: fresh targeted Sentry searches. Tier3: cursor pagination only if 1+2 empty."""
    if not triage_simple_first:
        issues, next_cursor, pages = fetch_issue_pages(
            client,
            query=base_query,
            page_size=page_size,
            start_cursor=start_cursor,
            max_pages=max_pages,
        )
        candidates, tier = select_tier_candidates(
            issues, branched=branched, excluded=excluded, triage_simple_first=False
        )
        return candidates, tier, issues, next_cursor, pages

    tier1_queries, tier2_queries = _get_tier_search_queries()

    # --- tier1: always search first (ignore pagination cursor) ---
    tier1_issues: list[Any] = []
    for term in tier1_queries:
        tier1_issues.extend(
            search_issues(
                client,
                search_term=term,
                page_size=page_size,
                branched=branched,
                excluded=excluded,
                required_tier=1,
            )
        )
    tier1_issues = dedupe_issues(tier1_issues)
    tier1_issues = [i for i in tier1_issues if classify_issue_tier(i) == 1]
    if tier1_issues:
        return (
            [issue_to_candidate(i, 1) for i in tier1_issues],
            1,
            tier1_issues,
            start_cursor,
            0,
        )

    # --- tier2: targeted + general unresolved scan (no cursor) ---
    tier2_issues: list[Any] = []
    for term in tier2_queries:
        tier2_issues.extend(
            search_issues(
                client,
                search_term=term,
                page_size=page_size,
                branched=branched,
                excluded=excluded,
                required_tier=2,
            )
        )
    for page, _link in client.iter_unresolved_issue_pages(
        query=base_query,
        limit=page_size,
        cursor=None,
        max_pages=min(3, max_pages),
    ):
        for issue in page:
            if should_skip_issue(issue, branched=branched, excluded=excluded):
                continue
            if classify_issue_tier(issue) == 2:
                tier2_issues.append(issue)
    tier2_issues = dedupe_issues(tier2_issues)
    tier2_issues = [i for i in tier2_issues if classify_issue_tier(i) == 2]
    if tier2_issues:
        return (
            [issue_to_candidate(i, 2) for i in tier2_issues],
            2,
            tier2_issues,
            start_cursor,
            0,
        )

    # --- tier3: only when tier1+2 exhausted — use cursor pagination ---
    issues, next_cursor, pages = fetch_issue_pages(
        client,
        query=base_query,
        page_size=page_size,
        start_cursor=start_cursor,
        max_pages=max_pages,
    )
    if not issues and start_cursor:
        issues, next_cursor, pages = fetch_issue_pages(
            client,
            query=base_query,
            page_size=page_size,
            start_cursor=None,
            max_pages=max_pages,
        )

    tier3_issues = [
        i
        for i in issues
        if not should_skip_issue(i, branched=branched, excluded=excluded)
        and classify_issue_tier(i) == 3
    ]
    if tier3_issues:
        return (
            [issue_to_candidate(i, 3) for i in tier3_issues],
            3,
            tier3_issues,
            next_cursor,
            pages,
        )

    # Fallback: any remaining actionable issue on this page
    candidates, tier = select_tier_candidates(
        issues, branched=branched, excluded=excluded, triage_simple_first=True
    )
    return candidates, tier, issues, next_cursor, pages


def build_effective_query(base_query: str, excluded_short_ids: Iterable[str]) -> str:
    query = base_query.strip()
    for short_id in excluded_short_ids:
        token = short_id.strip()
        if not token:
            continue
        query += f" !issue:{token}"
    return re.sub(r"\s+", " ", query).strip()


def _cursor_from_link_header(link_header: str | None) -> str | None:
    if not link_header:
        return None
    for part in link_header.split(","):
        if 'rel="next"' not in part:
            continue
        match = re.search(r"<([^>]+)>", part)
        if not match:
            continue
        parsed = urlparse(match.group(1))
        cursor = parse_qs(parsed.query).get("cursor", [None])[0]
        return cursor
    return None


def fetch_issue_pages(
    client: Any,
    *,
    query: str,
    page_size: int,
    start_cursor: str | None,
    max_pages: int,
) -> tuple[list[Any], str | None, int]:
    issues: list[SentryIssue] = []
    cursor = start_cursor
    pages = 0
    next_cursor: str | None = None

    for page_issues, link_header in client.iter_unresolved_issue_pages(
        query=query,
        limit=page_size,
        cursor=cursor,
        max_pages=max_pages,
    ):
        pages += 1
        issues.extend(page_issues)
        next_cursor = _cursor_from_link_header(link_header)
        if not next_cursor:
            break

    return issues, next_cursor, pages


def should_skip_issue(
    issue: Any,
    *,
    branched: set[str],
    excluded: set[str],
) -> str | None:
    if issue.short_id in branched:
        return "already_branched"
    if issue.short_id in excluded:
        return "excluded_page"
    return None


def select_tier_candidates(
    issues: list[Any],
    *,
    branched: set[str],
    excluded: set[str],
    triage_simple_first: bool,
) -> tuple[list[dict[str, Any]], int | None]:
    """Return candidates at the highest-priority tier that has actionable issues."""
    eligible: list[tuple[int, dict[str, Any]]] = []

    for issue in issues:
        if should_skip_issue(issue, branched=branched, excluded=excluded):
            continue
        tier = classify_issue_tier(issue) if triage_simple_first else 2
        eligible.append(
            (
                tier,
                {
                    "short_id": issue.short_id,
                    "title": issue.title,
                    "permalink": issue.permalink,
                    "id": issue.id,
                    "tier": f"tier{tier}",
                },
            )
        )

    if not eligible:
        return [], None

    best_tier = min(tier for tier, _ in eligible)
    candidates = [item for tier, item in eligible if tier == best_tier]
    return candidates, best_tier


def prepare(state_dir: Path, script_dir: Path) -> int:
    repo_root = Path(os.environ.get("REPO_ROOT", script_dir.parent.parent)).resolve()
    project_slug = os.environ["SENTRY_PROJECT_SLUG"]
    base_query = os.environ.get("SENTRY_QUERY", "is:unresolved level:error")
    page_size = min(100, max(1, env_int("SENTRY_PAGE_SIZE", 100)))
    max_pages = max(1, env_int("SENTRY_MAX_PAGES", 10))
    triage_simple_first = env_bool("SENTRY_TRIAGE_SIMPLE_FIRST", True)

    state_path = state_dir / STATE_FILE
    state = PaginationState.load(state_path)
    branched = list_branched_short_ids(repo_root, project_slug)
    excluded = set(state.excluded_short_ids)

    effective_query = build_effective_query(base_query, excluded)
    candidates: list[dict[str, Any]] = []
    selected_tier: int | None = None
    pages_fetched = 0
    next_cursor: str | None = None

    token = os.environ.get("SENTRY_AUTH_TOKEN", "").strip()
    if token:
        from sentry_client import SentryClient

        client = SentryClient(
            auth_token=token,
            org_slug=os.environ["SENTRY_ORG_SLUG"],
            region_url=os.environ.get("SENTRY_REGION_URL", "https://us.sentry.io"),
            project_slug=project_slug,
        )
        candidates, selected_tier, _issues, next_cursor, pages_fetched = (
            fetch_candidates_by_tier_priority(
                client,
                base_query=base_query,
                page_size=page_size,
                max_pages=max_pages,
                branched=branched,
                excluded=excluded,
                triage_simple_first=triage_simple_first,
                start_cursor=state.api_cursor,
            )
        )

        # Reset cursor when we found tier1/2 — don't skip ahead past app bugs
        if selected_tier in (1, 2):
            state.api_cursor = None
        else:
            state.api_cursor = next_cursor
        state.pages_fetched += pages_fetched
        state.save(state_path)
    else:
        pages_fetched = 0
        next_cursor = None

    candidates_path = state_dir / CANDIDATES_FILE
    candidates_path.write_text(json.dumps(candidates, indent=2) + "\n", encoding="utf-8")

    context_lines = [
        f"effective_query={effective_query}",
        f"page_size={page_size}",
        f"max_pages={max_pages}",
        f"triage_simple_first={str(triage_simple_first).lower()}",
        f"selected_tier={f'tier{selected_tier}' if selected_tier else 'none'}",
        f"excluded_count={len(excluded)}",
        f"branched_count={len(branched)}",
        f"candidate_count={len(candidates)}",
        f"pages_fetched={pages_fetched}",
        f"has_api_token={'true' if token else 'false'}",
        f"api_cursor={'set' if next_cursor else 'none'}",
    ]
    (state_dir / CONTEXT_FILE).write_text("\n".join(context_lines) + "\n", encoding="utf-8")

    print(f"prepare: candidates={len(candidates)} query={effective_query}")
    return 0


def post_run(state_dir: Path, result_env: Path) -> int:
    if not result_env.exists():
        return 0

    values: dict[str, str] = {}
    for line in result_env.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()

    state_path = state_dir / STATE_FILE
    state = PaginationState.load(state_path)

    if values.get("BRANCH_NAME"):
        return 0

    if values.get("NO_ACTION") != "true":
        return 0

    searched = [
        item.strip()
        for item in values.get("SEARCHED_ISSUES", "").split(",")
        if item.strip()
    ]
    if not searched:
        return 0

    excluded = set(state.excluded_short_ids)
    excluded.update(searched)
    state.excluded_short_ids = sorted(excluded)
    state.save(state_path)
    print(f"post_run: advanced pagination, excluded={len(state.excluded_short_ids)}")
    return 0


def reset(state_dir: Path) -> int:
    state_path = state_dir / STATE_FILE
    if state_path.exists():
        state_path.unlink()
    candidates = state_dir / CANDIDATES_FILE
    if candidates.exists():
        candidates.unlink()
    print("pagination state reset")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Sentry pagination helper")
    parser.add_argument(
        "--state-dir",
        default=str(Path(__file__).resolve().parent / ".state"),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("prepare", help="Build search query and optional candidate queue")
    post = sub.add_parser("post-run", help="Advance pagination after NO_ACTION")
    post.add_argument("--result", required=True, help="Path to run-result.env")
    sub.add_parser("reset", help="Clear pagination state")

    args = parser.parse_args()
    script_dir = Path(__file__).resolve().parent
    load_env_file(script_dir / "config.env")
    state_dir = Path(args.state_dir)

    if args.command == "prepare":
        return prepare(state_dir, script_dir)
    if args.command == "post-run":
        return post_run(state_dir, Path(args.result))
    if args.command == "reset":
        return reset(state_dir)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
