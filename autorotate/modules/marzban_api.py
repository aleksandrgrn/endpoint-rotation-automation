#!/usr/bin/env python3
"""Shared Marzban API helpers (stdlib-only).

Why
---
We have multiple scripts that need to talk to Marzban:
- `marzban_state.py` (read-only)
- `marzban_update.py` (read + patch + restart)

This module centralizes the common parts (token retrieval, HTTP requests,
GET core config, and Reality inbound navigation) to avoid drift.

Design constraints
------------------
- stdlib only (urllib)
- usable both as a package import (`autorotate.modules.*`) and as a direct
  script-relative import (see callers with try/except import)
"""

from __future__ import annotations

import json
import socket
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

TOKEN_KEYS: Tuple[str, ...] = ("access_token", "token")


class MarzbanApiError(RuntimeError):
    """Base class for Marzban API related errors."""


class MarzbanConnectError(MarzbanApiError):
    """Raised when a connection to Marzban cannot be established."""


class MarzbanTimeoutError(MarzbanApiError):
    """Raised when a Marzban HTTP request times out."""


class MarzbanHttpStatusError(MarzbanApiError):
    """Raised when Marzban returns an unexpected HTTP status."""


def build_url(base_url: str, path: str) -> str:
    return base_url.rstrip("/") + path


def http_request(
    method: str,
    url: str,
    data: Optional[bytes] = None,
    headers: Optional[Dict[str, str]] = None,
    timeout: float = 10,
) -> Tuple[int, bytes]:
    request = urllib.request.Request(url, data=data, method=method)
    for key, value in (headers or {}).items():
        request.add_header(key, value)

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.getcode(), response.read()
    except urllib.error.HTTPError as exc:
        # HTTPError still has a response body.
        return exc.code, exc.read()
    except urllib.error.URLError as exc:
        # Connection-level failures (DNS, refused, etc.)
        # NOTE: timeouts are frequently wrapped as URLError(reason=socket.timeout(...)).
        reason = getattr(exc, "reason", None)
        if isinstance(reason, (socket.timeout, TimeoutError)):
            raise MarzbanTimeoutError(str(exc))
        raise MarzbanConnectError(str(exc))
    except TimeoutError as exc:
        raise MarzbanTimeoutError(str(exc))
    except socket.timeout as exc:
        raise MarzbanTimeoutError(str(exc))


def parse_json(body: bytes, context: str) -> Any:
    if not body:
        return None
    try:
        return json.loads(body.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON in {context}: {exc}")


def get_token(
    base_url: str,
    username: str,
    password: str,
    *,
    log: Optional[Callable[[str], None]] = None,
) -> str:
    """Retrieve a Marzban admin token.

    This tries a few common payload formats for compatibility across versions.
    """

    def _log(message: str) -> None:
        if log is not None:
            try:
                log(message)
            except Exception:
                # Don't let logging break auth.
                pass

    url = build_url(base_url, "/api/admin/token")
    attempts: List[Tuple[str, Dict[str, str]]] = [
        ("form", {"username": username, "password": password}),
        ("form", {"username": username, "password": password, "grant_type": "password"}),
        ("json", {"username": username, "password": password}),
    ]

    for mode, payload in attempts:
        if mode == "form":
            data = urllib.parse.urlencode(payload).encode("utf-8")
            headers = {"Content-Type": "application/x-www-form-urlencoded"}
        else:
            data = json.dumps(payload).encode("utf-8")
            headers = {"Content-Type": "application/json"}

        status, body = http_request("POST", url, data=data, headers=headers)
        if status == 200:
            token_payload = parse_json(body, "token response")
            if not isinstance(token_payload, dict):
                raise RuntimeError("Token response is not JSON object")
            for key in TOKEN_KEYS:
                token = token_payload.get(key)
                if token:
                    return str(token)
            raise RuntimeError("Token not found in response")

        if status in (400, 401, 403, 415, 422):
            _log(f"Token attempt ({mode}) failed with status {status}, trying next")
            continue

        raise MarzbanHttpStatusError(f"Token request failed with status {status}")

    raise MarzbanApiError("All token attempts failed")


def collect_inbound_lists(obj: Any) -> Iterable[List[Dict[str, Any]]]:
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == "inbounds" and isinstance(value, list):
                yield value
            yield from collect_inbound_lists(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from collect_inbound_lists(item)


def find_inbound(config: Dict[str, Any], tag: str) -> Dict[str, Any]:
    matches: List[Dict[str, Any]] = []
    for inbound_list in collect_inbound_lists(config):
        for inbound in inbound_list:
            if isinstance(inbound, dict) and inbound.get("tag") == tag:
                matches.append(inbound)
    if len(matches) != 1:
        raise RuntimeError(f"Inbound tag '{tag}' not found uniquely (found {len(matches)})")
    return matches[0]


def find_reality_settings(inbound: Dict[str, Any]) -> Dict[str, Any]:
    candidates: List[Dict[str, Any]] = []
    if isinstance(inbound.get("realitySettings"), dict):
        candidates.append(inbound["realitySettings"])
    stream_settings = inbound.get("streamSettings")
    if isinstance(stream_settings, dict) and isinstance(stream_settings.get("realitySettings"), dict):
        candidates.append(stream_settings["realitySettings"])
    if len(candidates) != 1:
        raise RuntimeError("realitySettings path is ambiguous or missing")
    return candidates[0]


def load_core_config(base_url: str, token: str) -> Dict[str, Any]:
    url = build_url(base_url, "/api/core/config")
    headers = {"Authorization": f"Bearer {token}"}
    status, body = http_request("GET", url, headers=headers)
    if status != 200:
        raise MarzbanHttpStatusError(f"GET core config failed with status {status}")
    payload = parse_json(body, "core config")
    if not isinstance(payload, dict):
        raise RuntimeError("Core config response is not JSON object")
    return payload
