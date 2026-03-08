#!/usr/bin/env python3
"""Patch Marzban core config for Xray Reality inbound.

This script:
- retrieves admin token
- GETs core config
- finds the inbound by XRAY_INBOUND_TAG
- patches realitySettings.dest and realitySettings.serverNames
- PUTs core config
- restarts core
- verifies applied state
- rolls back from a local backup on verify failure

Output
------
Machine-readable KEY=VALUE lines to stdout:
- STATUS=ok|noop|fail
- OLD_DEST=<domain>
- NEW_DEST=<domain>
- REASON=<reason_code>
- OLD_SERVERNAMES=<json>
- NEW_SERVERNAMES=<json>

Notes
-----
- stdlib only
- error reasons are designed for consumption by autorotate/bin/rotate.sh
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

try:
    # Package import (tests / repo usage)
    from autorotate.modules import marzban_api as api
except Exception:  # pragma: no cover
    # Script-relative import (when copied/deployed standalone)
    import marzban_api as api  # type: ignore

SUCCESS_EXIT = 0
FAIL_EXIT = 1


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def print_result(
    status: str,
    old_dest: str,
    new_dest: str,
    reason: str,
    old_server_names: Optional[List[str]] = None,
    new_server_names: Optional[List[str]] = None,
) -> None:
    print(f"STATUS={status}")
    print(f"OLD_DEST={old_dest}")
    print(f"NEW_DEST={new_dest}")
    print(f"REASON={reason}")
    if old_server_names is not None:
        print(f"OLD_SERVERNAMES={json.dumps(old_server_names, ensure_ascii=False)}")
    if new_server_names is not None:
        print(f"NEW_SERVERNAMES={json.dumps(new_server_names, ensure_ascii=False)}")


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required env: {name}")
    return value


def normalize_dest(dest_value: Optional[str]) -> str:
    if not dest_value:
        return ""
    dest_value = str(dest_value).strip()
    if dest_value.endswith(":443"):
        return dest_value[:-4]
    return dest_value


def is_valid_domain(host: str) -> bool:
    host = (host or "").strip()

    if not host:
        return False
    if host != host.lower():
        return False
    if host.startswith("*."):
        return False
    if "." not in host:
        return False
    if len(host) > 253:
        return False

    # Basic LDH (letters/digits/hyphen) + dots.
    # No underscores, no unicode/punycode validation here.
    if not re.fullmatch(r"[a-z0-9.-]+", host):
        return False
    if not host[0].isalnum() or not host[-1].isalnum():
        return False

    labels = host.split(".")
    if len(labels) < 2:
        return False

    for label in labels:
        if not label:
            return False  # disallow empty labels (a..b)
        if len(label) > 63:
            return False
        if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", label):
            return False

    return True


def save_backup(config: Dict[str, Any], state_dir: str) -> str:
    backups_dir = os.path.join(state_dir, "backups")

    # Ensure state directories are private (best-effort).
    # Note: os.makedirs(mode=...) is affected by umask, so we also chmod.
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    os.makedirs(backups_dir, mode=0o700, exist_ok=True)
    try:
        os.chmod(state_dir, 0o700)
    except OSError:
        pass
    try:
        os.chmod(backups_dir, 0o700)
    except OSError:
        pass

    # Use nanoseconds to avoid collisions when multiple backups happen within the same second.
    timestamp = time.time_ns()
    backup_path = os.path.join(backups_dir, f"core-config.{timestamp}.json")
    with open(backup_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
    os.chmod(backup_path, 0o600)

    backups = sorted(
        [
            os.path.join(backups_dir, filename)
            for filename in os.listdir(backups_dir)
            if filename.startswith("core-config.") and filename.endswith(".json")
        ]
    )
    if len(backups) > 10:
        for old in backups[: len(backups) - 10]:
            try:
                os.remove(old)
            except OSError as exc:
                eprint(f"Failed to remove old backup {old}: {exc}")

    return backup_path


def put_core_config(base_url: str, token: str, config: Dict[str, Any]) -> None:
    url = api.build_url(base_url, "/api/core/config")
    data = json.dumps(config).encode("utf-8")
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    status, _ = api.http_request("PUT", url, data=data, headers=headers)
    if status not in (200, 204):
        raise api.MarzbanHttpStatusError(f"PUT core config failed with status {status}")


def restart_core(base_url: str, token: str) -> None:
    url = api.build_url(base_url, "/api/core/restart")
    headers = {"Authorization": f"Bearer {token}"}
    status, _ = api.http_request("POST", url, headers=headers)
    if status not in (200, 204):
        raise api.MarzbanHttpStatusError(f"Core restart failed with status {status}")


def verify_apply(base_url: str, token: str, tag: str, new_host: str) -> Tuple[bool, Optional[str]]:
    expected_dest = f"{new_host}:443"
    for attempt in range(10):
        if attempt == 0:
            time.sleep(3)
        else:
            time.sleep(1)
        try:
            config = api.load_core_config(base_url, token)
            inbound = api.find_inbound(config, tag)
            reality_settings = api.find_reality_settings(inbound)
            dest_value = str(reality_settings.get("dest", "")).strip()
            server_names = reality_settings.get("serverNames")
            if dest_value == expected_dest and server_names == [new_host]:
                return True, None
        except Exception as exc:
            eprint(f"Verify attempt {attempt + 1} failed: {exc}")
    return False, "verify_failed"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Patch Marzban core config for Reality.")
    parser.add_argument("--new-host", required=True, help="New dest hostname")
    parser.add_argument("--dry-run", action="store_true", help="Do not apply changes")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    old_dest = ""
    new_dest = args.new_host.strip().lower()

    try:
        marzban_url = require_env("MARZBAN_URL")
        marzban_user = require_env("MARZBAN_USER")
        marzban_pass = require_env("MARZBAN_PASS")
        inbound_tag = require_env("XRAY_INBOUND_TAG")

        # STATE_DIR is used for backups. Provide a safe default to match rotate.sh.
        # In production, it is still recommended to set STATE_DIR explicitly.
        state_dir = os.getenv("STATE_DIR", "/var/lib/reality-autorotate").strip() or "/var/lib/reality-autorotate"

    except RuntimeError as exc:
        eprint(str(exc))
        print_result("fail", old_dest, new_dest, "missing_env")
        return FAIL_EXIT

    if not is_valid_domain(new_dest):
        eprint(f"Invalid new host: {new_dest}")
        print_result("fail", old_dest, new_dest, "invalid_new_host")
        return FAIL_EXIT

    try:
        token = api.get_token(marzban_url, marzban_user, marzban_pass, log=eprint)
        config = api.load_core_config(marzban_url, token)
        inbound = api.find_inbound(config, inbound_tag)
        reality_settings = api.find_reality_settings(inbound)

        dest_value = reality_settings.get("dest")
        if dest_value is None:
            raise RuntimeError("Current dest is missing")

        old_dest = normalize_dest(str(dest_value))
        old_server_names = reality_settings.get("serverNames")
        if not isinstance(old_server_names, list):
            old_server_names = []

        if not is_valid_domain(old_dest):
            raise RuntimeError("Current dest is invalid")

        if new_dest == old_dest:
            print_result("noop", old_dest, new_dest, "already_current", old_server_names, [new_dest])
            return SUCCESS_EXIT

        if args.dry_run:
            print_result("ok", old_dest, new_dest, "dry_run", old_server_names, [new_dest])
            return SUCCESS_EXIT

        backup_path = save_backup(config, state_dir)
        eprint(f"Backup saved to {backup_path}")

        reality_settings["dest"] = f"{new_dest}:443"
        reality_settings["serverNames"] = [new_dest]

        put_core_config(marzban_url, token, config)
        restart_core(marzban_url, token)

        verified, reason = verify_apply(marzban_url, token, inbound_tag, new_dest)
        if not verified:
            eprint("Verify failed, attempting rollback")
            try:
                with open(backup_path, "r", encoding="utf-8") as handle:
                    backup_config = json.load(handle)
                put_core_config(marzban_url, token, backup_config)
                restart_core(marzban_url, token)
            except Exception as exc:
                eprint(f"Rollback failed: {exc}")
                print_result("fail", old_dest, new_dest, "rollback_failed", old_server_names, [new_dest])
                return FAIL_EXIT

            print_result("fail", old_dest, new_dest, reason or "verify_failed", old_server_names, [new_dest])
            return FAIL_EXIT

        print_result("ok", old_dest, new_dest, "updated", old_server_names, [new_dest])
        return SUCCESS_EXIT

    except api.MarzbanTimeoutError as exc:
        eprint(str(exc))
        print_result("fail", old_dest, new_dest, "timeout")
        return FAIL_EXIT
    except api.MarzbanConnectError as exc:
        eprint(str(exc))
        print_result("fail", old_dest, new_dest, "connect_failed")
        return FAIL_EXIT
    except api.MarzbanHttpStatusError as exc:
        eprint(str(exc))
        print_result("fail", old_dest, new_dest, "http_status")
        return FAIL_EXIT
    except api.MarzbanApiError as exc:
        eprint(str(exc))
        print_result("fail", old_dest, new_dest, "api_error")
        return FAIL_EXIT
    except Exception as exc:
        eprint(str(exc))
        print_result("fail", old_dest, new_dest, "exception")
        return FAIL_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
