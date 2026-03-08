#!/usr/bin/env bash
set -Eeuo pipefail

# Ensure private files (state/backups) are not created world-readable.
umask 077

usage() {
  echo "Usage: $0 --trigger watchdog|manual [--dry-run]" >&2
}

TRIGGER=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --trigger)
      TRIGGER="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$TRIGGER" ]]; then
  usage
  exit 2
fi

if [[ "$TRIGGER" != "watchdog" && "$TRIGGER" != "manual" ]]; then
  echo "Invalid trigger: $TRIGGER" >&2
  exit 2
fi

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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$SCRIPT_DIR/../modules"
SCAN_PICK="$MODULE_DIR/scan_pick.sh"
MARZBAN_UPDATE="$MODULE_DIR/marzban_update.py"
TG_NOTIFY="$MODULE_DIR/telegram_notify.sh"

mkdir -p "$STATE_DIR" "$STATE_DIR/backups"
chmod 700 "$STATE_DIR" "$STATE_DIR/backups" 2>/dev/null || true

exec 9>"$STATE_DIR/autorotate.lock"
if ! flock -n 9; then
  echo "Rotate lock is held, exiting" >&2
  exit 0
fi

CURRENT_DEST_FILE="$STATE_DIR/current_dest"
LAST_ROTATE_FILE="$STATE_DIR/last_rotate_ts"
FAIL_COUNT_FILE="$STATE_DIR/fail_count"
LAST_NO_CANDIDATES_FILE="$STATE_DIR/last_no_candidates_ts"
LAST_DRY_RUN_FILE="$STATE_DIR/last_dry_run_ts"
LAST_SCANNER_FAILED_FILE="$STATE_DIR/last_scanner_failed_ts"
LAST_UPDATE_FAILED_FILE="$STATE_DIR/last_update_failed_ts"

current_dest=""
if [[ -f "$CURRENT_DEST_FILE" ]]; then
  current_dest="$(<"$CURRENT_DEST_FILE")"
  current_dest="${current_dest%%$'\r'}"
  current_dest="${current_dest%%$'\n'}"
fi

get_marzban_state() {
  python3 "$MODULE_DIR/marzban_state.py" 2>/dev/null
}

normalize_dest() {
  local dest="$1"
  if [[ "$dest" == *":443" ]]; then
    echo "${dest%:443}"
  else
    echo "$dest"
  fi
}

should_send() {
  local ts_file="$1"
  local now last
  now=$(date +%s)
  last=0

  if [[ -f "$ts_file" ]]; then
    if ! last="$(<"$ts_file")"; then
      last=0
    fi
    last="${last%%$'\r'}"
    last="${last%%$'\n'}"
    if [[ ! "$last" =~ ^[0-9]+$ ]]; then
      last=0
    fi
  fi

  if (( now - last < 1800 )); then
    return 1
  fi

  # Persist timestamp. If persistence fails, suppress notification to avoid spamming.
  if ! printf '%s\n' "$now" >"$ts_file"; then
    echo "WARN: failed to persist anti-spam timestamp: $ts_file" >&2
    return 1
  fi
  return 0
}

send_telegram() {
  local message="$1"
  if [[ -z "${TG_TOKEN:-}" || -z "${TG_ID:-}" ]]; then
    echo "Telegram not configured, skipping notification" >&2
    return 0
  fi

  # Best-effort: notification failures must not fail rotate.
  if ! "$TG_NOTIFY" "$message"; then
    echo "WARN: Telegram send failed (ignored)" >&2
  fi
  return 0
}

verify_marzban_state() {
  local expected_host="$1"
  local output
  if ! output="$(get_marzban_state 2>/dev/null)"; then
    return 1
  fi
  local dest_value=""
  local servernames_json=""
  while IFS= read -r line; do
    case "$line" in
      DEST=*) dest_value="${line#DEST=}" ;;
      SERVERNAMES=*) servernames_json="${line#SERVERNAMES=}" ;;
    esac
  done <<< "$output"

  local normalized_dest
  normalized_dest="$(normalize_dest "$dest_value")"
  local expected_servernames="[\"${expected_host}\"]"
  if [[ "$normalized_dest" == "$expected_host" && "$servernames_json" == "$expected_servernames" ]]; then
    return 0
  fi
  return 1
}

if [[ -z "$current_dest" ]]; then
  if marzban_output="$(get_marzban_state 2>/dev/null)"; then
    while IFS= read -r line; do
      case "$line" in
        DEST=*) current_dest="$(normalize_dest "${line#DEST=}")" ;;
      esac
    done <<< "$marzban_output"

    if [[ -n "$current_dest" && "$DRY_RUN" -eq 0 ]]; then
      echo "$current_dest" > "$CURRENT_DEST_FILE"
    fi
  else
    echo "Failed to read current dest from Marzban" >&2
  fi
fi

cd "$PROJECT_ROOT"

new_dest=""
set +e
new_dest="$($SCAN_PICK "$current_dest")"
scan_rc=$?
set -e

if [[ "$scan_rc" -ne 0 ]]; then
  # scan_pick exit codes:
  #  - 1  => no_valid_candidates
  #  - 10 => scanner_failed (legacy/fallback)
  #  - 11 => pipeline_script_missing
  #  - 12 => pipeline_nonzero
  #  - 13 => best_domains_missing
  #  - 14 => best_domains_empty

  scanner_reason=""
  case "$scan_rc" in
    10) scanner_reason="scanner_failed" ;;
    11) scanner_reason="pipeline_script_missing" ;;
    12) scanner_reason="pipeline_nonzero" ;;
    13) scanner_reason="best_domains_missing" ;;
    14) scanner_reason="best_domains_empty" ;;
  esac

  if [[ -n "$scanner_reason" ]]; then
    if should_send "$LAST_SCANNER_FAILED_FILE"; then
      send_telegram "<b>Reality rotate</b>\nTrigger: ${TRIGGER}\nStatus: noop\nReason: ${scanner_reason}\nCurrent: ${current_dest}"
    fi
  else
    if should_send "$LAST_NO_CANDIDATES_FILE"; then
      send_telegram "<b>Reality rotate</b>\nTrigger: ${TRIGGER}\nStatus: noop\nReason: no_valid_candidates\nCurrent: ${current_dest}"
    fi
  fi
  exit 0
fi

update_output=""
rc=0
set +e
if [[ "$DRY_RUN" -eq 1 ]]; then
  update_output="$(python3 "$MARZBAN_UPDATE" --new-host "$new_dest" --dry-run)"
  rc=$?
else
  update_output="$(python3 "$MARZBAN_UPDATE" --new-host "$new_dest")"
  rc=$?
fi
set -e

update_status=""
reason=""
old_dest=""
reported_new_dest=""
while IFS= read -r line; do
  case "$line" in
    STATUS=*) update_status="${line#STATUS=}" ;;
    OLD_DEST=*) old_dest="${line#OLD_DEST=}" ;;
    NEW_DEST=*) reported_new_dest="${line#NEW_DEST=}" ;;
    REASON=*) reason="${line#REASON=}" ;;
  esac
done <<< "$update_output"

# Fail-safe defaults:
# - if marzban_update exited non-zero OR didn't emit STATUS=, never report success.
if [[ "$rc" -ne 0 ]]; then
  update_status="fail"
  reason="${reason:-marzban_update_failed}"
elif [[ -z "$update_status" ]]; then
  update_status="fail"
  reason="${reason:-invalid_update_output}"
fi

old_dest="${old_dest:-$current_dest}"
reported_new_dest="${reported_new_dest:-$new_dest}"

# State updates:
# Source of truth for apply/verify is marzban_update.py (rc + STATUS=...).
# Extra Marzban API verify here is best-effort only and must not turn success into failure.
if [[ "$rc" -eq 0 && "$DRY_RUN" -eq 0 && "$update_status" != "fail" ]]; then
  if [[ "$update_status" == "ok" ]]; then
    if ! verify_marzban_state "$reported_new_dest"; then
      echo "WARN: extra post-verify failed (ignored); relying on marzban_update.py verify" >&2
    fi
    echo "$reported_new_dest" > "$CURRENT_DEST_FILE"
    date +%s > "$LAST_ROTATE_FILE"
    echo "0" > "$FAIL_COUNT_FILE"
  elif [[ "$update_status" == "noop" ]]; then
    # Sync local state with Marzban (e.g., when local current_dest was missing/outdated).
    effective_dest="$old_dest"
    if [[ -z "$effective_dest" ]]; then
      effective_dest="$reported_new_dest"
    fi
    if [[ -n "$effective_dest" ]]; then
      echo "$effective_dest" > "$CURRENT_DEST_FILE"
      echo "0" > "$FAIL_COUNT_FILE"
    fi
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if should_send "$LAST_DRY_RUN_FILE"; then
    send_telegram "<b>Reality rotate (DRY-RUN)</b>\nTrigger: ${TRIGGER}\nStatus: ${update_status}\nReason: ${reason}\nOld: ${old_dest}\nNew: ${reported_new_dest}"
  fi
else
  # Anti-spam for repeated failures in watchdog mode.
  # In manual mode we want immediate feedback every run.
  if [[ "$TRIGGER" == "watchdog" && "$update_status" == "fail" ]]; then
    if should_send "$LAST_UPDATE_FAILED_FILE"; then
      send_telegram "<b>Reality rotate</b>\nTrigger: ${TRIGGER}\nStatus: ${update_status}\nReason: ${reason}\nOld: ${old_dest}\nNew: ${reported_new_dest}"
    fi
  else
    send_telegram "<b>Reality rotate</b>\nTrigger: ${TRIGGER}\nStatus: ${update_status}\nReason: ${reason}\nOld: ${old_dest}\nNew: ${reported_new_dest}"
  fi
fi

exit "$rc"
