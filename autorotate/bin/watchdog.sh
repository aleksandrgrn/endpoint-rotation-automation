#!/usr/bin/env bash
set -Eeuo pipefail

# Ensure private files (state/backups) are not created world-readable.
umask 077

STATE_DIR="${STATE_DIR:-/var/lib/reality-autorotate}"
# Basic validation to avoid writing lock/state files into unexpected locations.
STATE_DIR="${STATE_DIR%%$'\r'}"
STATE_DIR="${STATE_DIR%%$'\n'}"
if [[ "$STATE_DIR" != "/" ]]; then
  STATE_DIR="${STATE_DIR%/}"
fi
if [[ -z "$STATE_DIR" || "$STATE_DIR" == "/" || "$STATE_DIR" != /* ]]; then
  echo "Invalid STATE_DIR: $STATE_DIR" >&2
  exit 2
fi

PROJECT_ROOT="${PROJECT_ROOT:?PROJECT_ROOT is required}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-5}"
DEST_FAIL_COUNT="${DEST_FAIL_COUNT:-5}"
ROTATE_COOLDOWN="${ROTATE_COOLDOWN:-300}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$SCRIPT_DIR/../modules"
VERIFY_SCRIPT="$MODULE_DIR/verify_cert.py"
ROTATE_SCRIPT="$SCRIPT_DIR/rotate.sh"

mkdir -p "$STATE_DIR" "$STATE_DIR/backups"
chmod 700 "$STATE_DIR" "$STATE_DIR/backups" 2>/dev/null || true

# Single-instance lock to avoid races and duplicate rotate invocations.
exec 9>"$STATE_DIR/watchdog.lock"
if ! flock -n 9; then
  exit 0
fi

CURRENT_DEST_FILE="$STATE_DIR/current_dest"
FAIL_COUNT_FILE="$STATE_DIR/fail_count"
LAST_ROTATE_FILE="$STATE_DIR/last_rotate_ts"

current_dest=""
if [[ -f "$CURRENT_DEST_FILE" ]]; then
  current_dest="$(<"$CURRENT_DEST_FILE")"
  current_dest="${current_dest%%$'\r'}"
  current_dest="${current_dest%%$'\n'}"
fi

normalize_dest() {
  local dest="$1"
  if [[ "$dest" == *":443" ]]; then
    echo "${dest%:443}"
  else
    echo "$dest"
  fi
}

get_marzban_dest() {
  python3 "$MODULE_DIR/marzban_state.py" 2>/dev/null
}

if [[ -z "$current_dest" ]]; then
  if marzban_output="$(get_marzban_dest 2>/dev/null)"; then
    while IFS= read -r line; do
      case "$line" in
        DEST=*) current_dest="$(normalize_dest "${line#DEST=}")" ;;
      esac
    done <<< "$marzban_output"

    if [[ -n "$current_dest" ]]; then
      echo "$current_dest" > "$CURRENT_DEST_FILE"
    fi
  else
    echo "Failed to read current dest from Marzban" >&2
  fi
fi

if [[ -z "$current_dest" ]]; then
  "$ROTATE_SCRIPT" --trigger watchdog
  exit 0
fi

read_int_file() {
  local path="$1" default_value="$2" value=""
  if [[ -f "$path" ]]; then
    value="$(<"$path" 2>/dev/null || true)"
    value="${value%%$'\r'}"
    value="${value%%$'\n'}"
  fi
  if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$value"
  fi
}

fail_count="$(read_int_file "$FAIL_COUNT_FILE" 0)"

if python3 "$VERIFY_SCRIPT" --host "$current_dest" --port 443 --timeout "$VERIFY_TIMEOUT" >/dev/null 2>&1; then
  echo "0" > "$FAIL_COUNT_FILE"
  exit 0
fi

fail_count=$((fail_count + 1))
echo "$fail_count" > "$FAIL_COUNT_FILE"

if (( fail_count < DEST_FAIL_COUNT )); then
  exit 0
fi

last_rotate="$(read_int_file "$LAST_ROTATE_FILE" 0)"

now=$(date +%s)
if (( now - last_rotate < ROTATE_COOLDOWN )); then
  exit 0
fi

"$ROTATE_SCRIPT" --trigger watchdog
