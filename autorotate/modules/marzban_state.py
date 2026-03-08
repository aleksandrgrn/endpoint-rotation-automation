#!/usr/bin/env python3
"""Read Marzban core config and print current Reality dest/serverNames.

Purpose
-------
This module exists to avoid duplicating Marzban API/token logic in multiple
bash scripts (rotate/watchdog).

Output (stdout)
---------------
Machine-readable KEY=VALUE lines:
- DEST=<dest>                      # as-is from config (may include :443)
- SERVERNAMES=<json array>          # JSON array (ensure_ascii=False)

Exit codes
----------
0: success
1: failure

Environment
-----------
Required:
- MARZBAN_URL
- MARZBAN_USER
- MARZBAN_PASS
- XRAY_INBOUND_TAG

Notes
-----
- Uses stdlib only.
- Intentionally minimal: only GET state.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

try:
    # Package import (tests / repo usage)
    from autorotate.modules import marzban_api as api
except Exception:  # pragma: no cover
    # Script-relative import (when copied/deployed standalone)
    import marzban_api as api  # type: ignore


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required env: {name}")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Print current Marzban Reality dest/serverNames.")
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="HTTP timeout in seconds (currently informational; reserved)",
    )
    return parser.parse_args()


def main() -> int:
    _args = parse_args()
    try:
        marzban_url = require_env("MARZBAN_URL")
        marzban_user = require_env("MARZBAN_USER")
        marzban_pass = require_env("MARZBAN_PASS")
        inbound_tag = require_env("XRAY_INBOUND_TAG")

        token = api.get_token(marzban_url, marzban_user, marzban_pass, log=eprint)
        config = api.load_core_config(marzban_url, token)
        inbound = api.find_inbound(config, inbound_tag)
        reality_settings = api.find_reality_settings(inbound)

        dest_value = str(reality_settings.get("dest", ""))
        server_names = reality_settings.get("serverNames")
        if not isinstance(server_names, list):
            server_names = []

        print(f"DEST={dest_value}")
        print(f"SERVERNAMES={json.dumps(server_names, ensure_ascii=False)}")
        return 0

    except Exception as exc:
        eprint(str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
