"""Create Bitbucket Cloud pull requests via REST API."""

from __future__ import annotations

from dataclasses import dataclass

import requests


@dataclass
class PullRequest:
    id: int
    url: str
    title: str


class BitbucketClient:
    def __init__(
        self,
        *,
        workspace: str,
        repo_slug: str,
        username: str | None = None,
        app_password: str | None = None,
        access_token: str | None = None,
    ) -> None:
        self.workspace = workspace
        self.repo_slug = repo_slug
        self.base = (
            f"https://api.bitbucket.org/2.0/repositories/{workspace}/{repo_slug}"
        )
        self.session = requests.Session()
        self.session.headers.update({"Content-Type": "application/json"})

        if access_token:
            # Repository / workspace HTTP access token (Bitbucket Cloud)
            self.session.headers["Authorization"] = f"Bearer {access_token}"
        elif username and app_password:
            self.session.auth = (username, app_password)
        else:
            raise ValueError(
                "Set BITBUCKET_ACCESS_TOKEN or "
                "BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD"
            )

    def create_pull_request(
        self,
        *,
        title: str,
        description: str,
        source_branch: str,
        destination_branch: str,
        draft: bool = True,
        close_source_branch: bool = True,
    ) -> PullRequest:
        payload = {
            "title": title,
            "description": description,
            "source": {"branch": {"name": source_branch}},
            "destination": {"branch": {"name": destination_branch}},
            "draft": draft,
            "close_source_branch": close_source_branch,
        }
        resp = self.session.post(f"{self.base}/pullrequests", json=payload, timeout=60)
        resp.raise_for_status()
        data = resp.json()
        return PullRequest(
            id=data["id"],
            url=data["links"]["html"]["href"],
            title=data["title"],
        )
