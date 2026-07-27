"""Minimal Sentry REST client (no paid services)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
import re

import requests


@dataclass
class SentryIssue:
    id: str
    short_id: str
    title: str
    permalink: str
    last_seen: str
    culprit: str | None
    metadata: dict[str, Any]


class SentryClient:
    def __init__(
        self,
        *,
        auth_token: str,
        org_slug: str,
        region_url: str,
        project_slug: str | None = None,
    ) -> None:
        self.org_slug = org_slug
        self.project_slug = project_slug
        self.base = region_url.rstrip("/") + "/api/0"
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {auth_token}",
                "Content-Type": "application/json",
            }
        )

    def list_unresolved_issues(
        self,
        *,
        query: str,
        limit: int = 10,
    ) -> list[SentryIssue]:
        issues: list[SentryIssue] = []
        for page, _link in self.iter_unresolved_issue_pages(
            query=query,
            limit=limit,
            max_pages=1,
        ):
            issues.extend(page)
            if len(issues) >= limit:
                break
        return issues[:limit]

    def iter_unresolved_issue_pages(
        self,
        *,
        query: str,
        limit: int = 100,
        cursor: str | None = None,
        max_pages: int = 10,
    ):
        params: dict[str, Any] = {"query": query, "limit": min(limit, 100)}
        if self.project_slug:
            params["query"] = f"project:{self.project_slug} {query}".strip()
        if cursor:
            params["cursor"] = cursor

        url = f"{self.base}/organizations/{self.org_slug}/issues/"
        pages = 0

        while url and pages < max_pages:
            resp = self.session.get(url, params=params, timeout=60)
            if resp.status_code == 403:
                raise PermissionError(
                    "Sentry API returned 403 Forbidden. The token in SENTRY_AUTH_TOKEN "
                    "cannot list issues. Create a new **User Auth Token** in Sentry "
                    "(Settings → Account → Auth Tokens) with scopes: "
                    "org:read, project:read, event:read. "
                    "Do not reuse the pubspec upload-only release token."
                ) from None
            resp.raise_for_status()
            items = resp.json()
            yield [self._to_issue(item) for item in items], resp.headers.get("Link")
            pages += 1
            params = {}
            link = resp.headers.get("Link", "")
            next_url = None
            if link:
                for part in link.split(","):
                    if 'rel="next"' in part:
                        match = re.search(r"<([^>]+)>", part)
                        if match:
                            next_url = match.group(1)
                            break
            url = next_url

    def get_latest_event(self, issue_id: str) -> dict[str, Any]:
        url = f"{self.base}/organizations/{self.org_slug}/issues/{issue_id}/events/latest/"
        resp = self.session.get(url, timeout=60)
        resp.raise_for_status()
        return resp.json()

    def get_issue(self, issue_id: str) -> dict[str, Any]:
        """Fetch full issue payload (status, lastSeen, count, …)."""
        url = f"{self.base}/organizations/{self.org_slug}/issues/{issue_id}/"
        resp = self.session.get(url, timeout=60)
        resp.raise_for_status()
        data = resp.json()
        if not isinstance(data, dict):
            raise RuntimeError(f"Unexpected Sentry issue payload for {issue_id}")
        return data

    def resolve_issue(self, issue_id: str) -> None:
        """Mark a Sentry issue resolved (requires event:write or issue:write scope)."""
        url = f"{self.base}/organizations/{self.org_slug}/issues/{issue_id}/"
        resp = self.session.put(url, json={"status": "resolved"}, timeout=60)
        resp.raise_for_status()

    def find_issue_id_by_short_id(self, short_id: str, *, query: str = "is:unresolved") -> str | None:
        for page, _link in self.iter_unresolved_issue_pages(
            query=f'{query} {short_id}',
            limit=25,
            max_pages=1,
        ):
            for issue in page:
                if issue.short_id.upper() == short_id.upper():
                    return issue.id
        return None

    def find_issue_by_short_id(self, short_id: str) -> SentryIssue | None:
        """Find issue by short id (unresolved first, then any status)."""
        for query in ("is:unresolved", ""):
            for page, _link in self.iter_unresolved_issue_pages(
                query=f"{query} {short_id}".strip(),
                limit=25,
                max_pages=1,
            ):
                for issue in page:
                    if issue.short_id.upper() == short_id.upper():
                        return issue
        return None

    @staticmethod
    def _to_issue(item: dict[str, Any]) -> SentryIssue:
        return SentryIssue(
            id=str(item["id"]),
            short_id=item.get("shortId", item["id"]),
            title=item.get("title", "Unknown"),
            permalink=item.get("permalink", ""),
            last_seen=item.get("lastSeen", ""),
            culprit=item.get("culprit"),
            metadata=item.get("metadata") or {},
        )
