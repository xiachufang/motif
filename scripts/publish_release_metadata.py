#!/usr/bin/env python3
"""Publish an immutable release asset as a per-platform stable pointer.

The generated JSON lives on the ``release-metadata`` branch. GitHub Pages
combines that branch's ``meta/`` directory with the normal site at deploy time.
Updates use the GitHub Contents API with optimistic retries so independent
platform jobs can safely update one product manifest concurrently.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from datetime import datetime, timezone
from typing import Any, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


SCHEMA_VERSION = 1
DEFAULT_BRANCH = "release-metadata"
_PLATFORM_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


class GitHubApiError(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(f"GitHub API returned HTTP {status}: {message}")
        self.status = status


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z"
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_asset_entry(
    *,
    artifact: Path,
    repository: str,
    tag: str,
    published_at: Optional[str] = None,
) -> dict[str, Any]:
    if not artifact.is_file():
        raise ValueError(f"release artifact does not exist: {artifact}")
    if repository.count("/") != 1:
        raise ValueError(f"invalid GitHub repository: {repository}")
    if not tag:
        raise ValueError("release tag must not be empty")

    encoded_tag = quote(tag, safe="")
    encoded_name = quote(artifact.name, safe="")
    version = tag[1:] if tag.startswith("v") else tag
    return {
        "file": artifact.name,
        "publishedAt": published_at or _utc_now(),
        "releasePage": f"https://github.com/{repository}/releases/tag/{encoded_tag}",
        "sha256": _sha256(artifact),
        "size": artifact.stat().st_size,
        "tag": tag,
        "url": (
            f"https://github.com/{repository}/releases/download/"
            f"{encoded_tag}/{encoded_name}"
        ),
        "version": version,
    }


def merge_manifest(
    existing: Optional[dict[str, Any]],
    *,
    product: str,
    platform: str,
    entry: dict[str, Any],
    updated_at: Optional[str] = None,
) -> dict[str, Any]:
    if existing is None:
        manifest: dict[str, Any] = {
            "schema": SCHEMA_VERSION,
            "channel": "stable",
            "product": product,
            "assets": {},
        }
    else:
        manifest = copy.deepcopy(existing)
        if manifest.get("schema") != SCHEMA_VERSION:
            raise ValueError("unsupported release metadata schema")
        if manifest.get("channel") != "stable":
            raise ValueError("release metadata channel is not stable")
        if manifest.get("product") != product:
            raise ValueError("release metadata product does not match")
        if not isinstance(manifest.get("assets"), dict):
            raise ValueError("release metadata assets must be an object")

    manifest["updatedAt"] = updated_at or _utc_now()
    manifest["assets"][platform] = copy.deepcopy(entry)
    return manifest


class GitHubClient:
    def __init__(self, *, repository: str, token: str, api_url: str):
        self.repository = repository
        self.token = token
        self.api_url = api_url.rstrip("/")

    def request(
        self, method: str, path: str, payload: Optional[dict[str, Any]] = None
    ) -> dict[str, Any]:
        data = None
        if payload is not None:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        suffix = f"/{path.lstrip('/')}" if path else ""
        request = Request(
            f"{self.api_url}/repos/{self.repository}{suffix}",
            data=data,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "User-Agent": "motif-release-metadata",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urlopen(request, timeout=30) as response:
                body = response.read()
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            try:
                decoded = json.loads(detail)
                detail = str(decoded.get("message", detail))
            except json.JSONDecodeError:
                pass
            raise GitHubApiError(error.code, detail) from error
        except URLError as error:
            raise RuntimeError(f"GitHub API request failed: {error}") from error
        if not body:
            return {}
        decoded = json.loads(body)
        if not isinstance(decoded, dict):
            raise RuntimeError("GitHub API response was not an object")
        return decoded

    def ensure_branch(self, branch: str) -> None:
        encoded_branch = quote(branch, safe="")
        try:
            self.request("GET", f"git/ref/heads/{encoded_branch}")
            return
        except GitHubApiError as error:
            if error.status != 404:
                raise

        repository = self.request("GET", "")
        default_branch = repository.get("default_branch")
        if not isinstance(default_branch, str) or not default_branch:
            raise RuntimeError("GitHub repository response has no default branch")
        base = self.request(
            "GET", f"git/ref/heads/{quote(default_branch, safe='')}"
        )
        target = base.get("object")
        base_sha = target.get("sha") if isinstance(target, dict) else None
        if not isinstance(base_sha, str):
            raise RuntimeError("GitHub default branch response has no commit SHA")
        try:
            self.request(
                "POST",
                "git/refs",
                {"ref": f"refs/heads/{branch}", "sha": base_sha},
            )
        except GitHubApiError as error:
            # Another platform job may have created the branch concurrently.
            if error.status != 422:
                raise

    def read_file(
        self, *, branch: str, path: str
    ) -> tuple[Optional[dict[str, Any]], Optional[str]]:
        encoded_path = quote(path, safe="/")
        encoded_branch = quote(branch, safe="")
        try:
            response = self.request(
                "GET", f"contents/{encoded_path}?ref={encoded_branch}"
            )
        except GitHubApiError as error:
            if error.status == 404:
                return None, None
            raise
        content = response.get("content")
        sha = response.get("sha")
        if not isinstance(content, str) or not isinstance(sha, str):
            raise RuntimeError("GitHub contents response is incomplete")
        decoded = json.loads(base64.b64decode(content).decode("utf-8"))
        if not isinstance(decoded, dict):
            raise RuntimeError("existing release metadata is not an object")
        return decoded, sha

    def write_file(
        self,
        *,
        branch: str,
        path: str,
        content: dict[str, Any],
        current_sha: Optional[str],
        message: str,
    ) -> None:
        encoded_path = quote(path, safe="/")
        rendered = json.dumps(
            content, ensure_ascii=False, indent=2, sort_keys=True
        ) + "\n"
        payload: dict[str, Any] = {
            "branch": branch,
            "content": base64.b64encode(rendered.encode("utf-8")).decode("ascii"),
            "message": message,
        }
        if current_sha is not None:
            payload["sha"] = current_sha
        self.request("PUT", f"contents/{encoded_path}", payload)


def publish(
    *,
    client: GitHubClient,
    branch: str,
    product: str,
    platform: str,
    entry: dict[str, Any],
) -> dict[str, Any]:
    path = f"meta/v1/{product}/stable.json"
    client.ensure_branch(branch)
    for attempt in range(1, 9):
        existing, current_sha = client.read_file(branch=branch, path=path)
        manifest = merge_manifest(
            existing,
            product=product,
            platform=platform,
            entry=entry,
        )
        try:
            client.write_file(
                branch=branch,
                path=path,
                content=manifest,
                current_sha=current_sha,
                message=f"meta: publish {product} {platform} {entry['version']}",
            )
            return manifest
        except GitHubApiError as error:
            if error.status not in (409, 422) or attempt == 8:
                raise
            time.sleep(attempt)
    raise AssertionError("unreachable")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", choices=("app", "motifd"), required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--tag", default=os.environ.get("GITHUB_REF_NAME"))
    parser.add_argument("--branch", default=DEFAULT_BRANCH)
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN"))
    parser.add_argument(
        "--api-url", default=os.environ.get("GITHUB_API_URL", "https://api.github.com")
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv or sys.argv[1:])
    if not _PLATFORM_RE.fullmatch(args.platform):
        raise ValueError(f"invalid platform key: {args.platform}")
    if not args.repository:
        raise ValueError("--repository or GITHUB_REPOSITORY is required")
    if not args.tag:
        raise ValueError("--tag or GITHUB_REF_NAME is required")

    entry = build_asset_entry(
        artifact=args.artifact,
        repository=args.repository,
        tag=args.tag,
    )
    if args.dry_run:
        print(
            json.dumps(
                merge_manifest(
                    None,
                    product=args.product,
                    platform=args.platform,
                    entry=entry,
                ),
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
        )
        return 0
    if not args.token:
        raise ValueError("--token or GITHUB_TOKEN is required")

    manifest = publish(
        client=GitHubClient(
            repository=args.repository,
            token=args.token,
            api_url=args.api_url,
        ),
        branch=args.branch,
        product=args.product,
        platform=args.platform,
        entry=entry,
    )
    print(
        f"Published {args.product}/{args.platform} {entry['version']} "
        f"({len(manifest['assets'])} stable platform(s))"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
