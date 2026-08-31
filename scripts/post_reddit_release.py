#!/usr/bin/env python3
"""Publish one Linthra release announcement through Reddit's OAuth Data API."""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

TOKEN_URL = "https://www.reddit.com/api/v1/access_token"
OAUTH_BASE = "https://oauth.reddit.com"
DEFAULT_USER_AGENT = "linux:io.github.thezupzup.linthra.releases:v1 (by /u/TheZupZup)"


class RedditPublishError(RuntimeError):
    """A publish failure that is safe to report without exposing credentials."""


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RedditPublishError(f"missing required environment variable {name}")
    return value


def _request_json(request: urllib.request.Request, *, context: str) -> dict[str, Any]:
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        # Do not print the body: auth failures can include request details and
        # there is no reason to risk reflecting credentials into Actions logs.
        raise RedditPublishError(f"{context} failed with HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RedditPublishError(f"{context} failed: {exc.reason}") from exc

    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise RedditPublishError(f"{context} returned invalid JSON") from exc
    if not isinstance(decoded, dict):
        raise RedditPublishError(f"{context} returned an unexpected response")
    return decoded


def exchange_refresh_token(
    client_id: str, client_secret: str, refresh_token: str, user_agent: str
) -> str:
    credentials = base64.b64encode(
        f"{client_id}:{client_secret}".encode("utf-8")
    ).decode("ascii")
    data = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        TOKEN_URL,
        data=data,
        headers={
            "Authorization": f"Basic {credentials}",
            "User-Agent": user_agent,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    payload = _request_json(request, context="Reddit OAuth token exchange")
    token = payload.get("access_token")
    if not isinstance(token, str) or not token:
        raise RedditPublishError("Reddit OAuth token exchange returned no access token")
    return token


def find_existing_announcement(
    access_token: str,
    user_agent: str,
    subreddit: str,
    release_url: str,
) -> str | None:
    query = urllib.parse.urlencode({"limit": 100, "raw_json": 1})
    request = urllib.request.Request(
        f"{OAUTH_BASE}/r/{urllib.parse.quote(subreddit)}/new?{query}",
        headers={
            "Authorization": f"bearer {access_token}",
            "User-Agent": user_agent,
        },
    )
    payload = _request_json(request, context="Reddit duplicate check")
    children = payload.get("data", {}).get("children", [])
    if not isinstance(children, list):
        raise RedditPublishError(
            "Reddit duplicate check returned an unexpected listing"
        )

    for child in children:
        if not isinstance(child, dict):
            continue
        data = child.get("data")
        if not isinstance(data, dict):
            continue
        selftext = data.get("selftext")
        if isinstance(selftext, str) and release_url in selftext:
            permalink = data.get("permalink")
            if isinstance(permalink, str) and permalink:
                return f"https://www.reddit.com{permalink}"
            return "already announced"
    return None


def submit_post(
    access_token: str,
    user_agent: str,
    subreddit: str,
    title: str,
    body: str,
) -> str:
    data = urllib.parse.urlencode(
        {
            "api_type": "json",
            "kind": "self",
            "sr": subreddit,
            "title": title,
            "text": body,
            "sendreplies": "true",
            "resubmit": "true",
            "raw_json": "1",
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{OAUTH_BASE}/api/submit",
        data=data,
        headers={
            "Authorization": f"bearer {access_token}",
            "User-Agent": user_agent,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    payload = _request_json(request, context="Reddit post submission")
    json_result = payload.get("json")
    if not isinstance(json_result, dict):
        raise RedditPublishError("Reddit post submission returned no json result")

    errors = json_result.get("errors")
    if isinstance(errors, list) and errors:
        safe_errors = []
        for item in errors:
            if isinstance(item, list) and len(item) >= 2:
                safe_errors.append(f"{item[0]}: {item[1]}")
            else:
                safe_errors.append("unknown Reddit API error")
        raise RedditPublishError("Reddit rejected the post: " + "; ".join(safe_errors))

    data_result = json_result.get("data")
    if not isinstance(data_result, dict):
        raise RedditPublishError("Reddit post submission returned no post data")
    url = data_result.get("url")
    if not isinstance(url, str) or not url.startswith("http"):
        raise RedditPublishError("Reddit post submission returned no post URL")
    return url


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--title-file", type=Path, required=True)
    parser.add_argument("--body-file", type=Path, required=True)
    parser.add_argument("--release-url", required=True)
    parser.add_argument("--subreddit", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        title = args.title_file.read_text(encoding="utf-8").strip()
        body = args.body_file.read_text(encoding="utf-8").strip()
        if not title or not body:
            raise RedditPublishError("generated Reddit title/body is empty")

        client_id = _required_env("REDDIT_CLIENT_ID")
        client_secret = _required_env("REDDIT_CLIENT_SECRET")
        refresh_token = _required_env("REDDIT_REFRESH_TOKEN")
        user_agent = os.environ.get("REDDIT_USER_AGENT", DEFAULT_USER_AGENT).strip()
        if not user_agent:
            raise RedditPublishError("REDDIT_USER_AGENT must not be empty")

        token = exchange_refresh_token(
            client_id, client_secret, refresh_token, user_agent
        )
        existing = find_existing_announcement(
            token, user_agent, args.subreddit, args.release_url
        )
        if existing is not None:
            print(f"Reddit announcement already exists: {existing}")
            return 0

        url = submit_post(token, user_agent, args.subreddit, title, body)
        print(f"Reddit announcement published: {url}")
        return 0
    except (OSError, RedditPublishError) as exc:
        print(f"reddit publish: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
