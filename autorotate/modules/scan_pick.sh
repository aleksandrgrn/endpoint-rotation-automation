#!/usr/bin/env bash
set -Eeuo pipefail

# Ensure private files (state/logs) are not created world-readable.
umask 077

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <current_dest>" >&2
  exit 2
fi

CURRENT_DEST="$1"
PROJECT_ROOT="${PROJECT_ROOT:?PROJECT_ROOT is required}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-5}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify_cert.py"

cd "$PROJECT_ROOT"

is_valid_domain() {
  local host="$1"

  # trim whitespace and CR/LF
  host="${host%%$'\r'}"
  host="${host%%$'\n'}"
  host="${host//[[:space:]]/}"

  [[ -n "$host" ]] || return 1
  [[ "$host" == "${host,,}" ]] || return 1
  [[ "$host" != "*."* ]] || return 1
  [[ "$host" == *.* ]] || return 1

  # RFC-ish limits (best-effort)
  (( ${#host} <= 253 )) || return 1

  # Only basic LDH chars (no underscores, no unicode). We also enforce start/end alnum.
  [[ "$host" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$host" =~ ^[a-z0-9] ]] || return 1
  [[ "$host" =~ [a-z0-9]$ ]] || return 1

  local IFS='.'
  local -a labels
  read -r -a labels <<<"$host"
  (( ${#labels[@]} >= 2 )) || return 1

  local label
  for label in "${labels[@]}"; do
    [[ -n "$label" ]] || return 1  # disallow empty label (a..b)
    (( ${#label} <= 63 )) || return 1

    # label must be alnum or alnum...alnum with internal '-'
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done

  return 0
}

if [[ ! -f "./reality-realtlscanner-pipeline.sh" ]]; then
  echo "Scanner script not found at $PROJECT_ROOT/reality-realtlscanner-pipeline.sh" >&2
  exit 11
fi

# Run via bash to avoid relying on executable bit.
# IMPORTANT: keep scan_pick stdout clean (must output ONLY the chosen domain).
# Therefore pipeline output is redirected to a log file.
SCANNER_MODE="${SCANNER_MODE:-offline}"
STATE_DIR="${STATE_DIR:-/var/lib/reality-autorotate}"
STATE_DIR="${STATE_DIR%%$'\r'}"
STATE_DIR="${STATE_DIR%%$'\n'}"
if [[ "$STATE_DIR" != "/" ]]; then
  STATE_DIR="${STATE_DIR%/}"
fi
if [[ -z "$STATE_DIR" || "$STATE_DIR" == "/" || "$STATE_DIR" != /* ]]; then
  echo "Invalid STATE_DIR: $STATE_DIR" >&2
  exit 2
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
PIPELINE_LOG="$STATE_DIR/scan_pick.pipeline.log"
SCAN_PICK_LOG_MAX_BYTES="${SCAN_PICK_LOG_MAX_BYTES:-1048576}"  # 1 MiB
SCAN_PICK_LOG_KEEP="${SCAN_PICK_LOG_KEEP:-5}"

rotate_log_best_effort() {
  local file="$1" max_bytes="$2" keep="$3"

  # Validate numeric inputs.
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=1
  (( keep >= 1 )) || keep=1

  [[ -f "$file" ]] || return 0

  local size
  size="$(wc -c <"$file" 2>/dev/null || echo 0)"
  size="${size//[[:space:]]/}"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0

  if (( size < max_bytes )); then
    return 0
  fi

  # Shift: file.(keep-1) -> file.keep, ..., file.1 -> file.2, file -> file.1
  local i
  for (( i=keep-1; i>=1; i-- )); do
    if [[ -f "$file.$i" ]]; then
      mv -f -- "$file.$i" "$file.$((i+1))" 2>/dev/null || return 0
    fi
  done

  mv -f -- "$file" "$file.1" 2>/dev/null || return 0

  # Remove files above retention (best-effort)
  for (( i=keep+1; i<=keep+20; i++ )); do
    [[ -f "$file.$i" ]] || continue
    rm -f -- "$file.$i" 2>/dev/null || true
  done
}

# Best-effort log rotation (must never fail scan_pick).
set +e
rotate_log_best_effort "$PIPELINE_LOG" "$SCAN_PICK_LOG_MAX_BYTES" "$SCAN_PICK_LOG_KEEP" 2>/dev/null
set -e

set +e
if [[ "$SCANNER_MODE" == "offline" ]]; then
  OFFLINE=1 bash ./reality-realtlscanner-pipeline.sh </dev/null >"$PIPELINE_LOG" 2>&1
else
  bash ./reality-realtlscanner-pipeline.sh </dev/null >"$PIPELINE_LOG" 2>&1
fi
pipeline_rc=$?
set -e
if [[ "$pipeline_rc" -ne 0 ]]; then
  echo "Scanner failed with exit code: $pipeline_rc" >&2
  exit 12
fi

BEST_DOMAINS_FILE="$PROJECT_ROOT/RealiTLScanner/04_best_domains.txt"
if [[ ! -f "$BEST_DOMAINS_FILE" ]]; then
  echo "Best domains file missing: $BEST_DOMAINS_FILE" >&2
  exit 13
fi
if [[ ! -s "$BEST_DOMAINS_FILE" ]]; then
  echo "Best domains file is empty: $BEST_DOMAINS_FILE" >&2
  exit 14
fi

while IFS= read -r candidate; do
  [[ -z "$candidate" ]] && continue

  # Normalize and validate candidate early (fail-safe).
  candidate="${candidate%%$'\r'}"
  candidate="${candidate%%$'\n'}"
  candidate="${candidate//[[:space:]]/}"

  if ! is_valid_domain "$candidate"; then
    continue
  fi

  if [[ -n "$CURRENT_DEST" && "$candidate" == "$CURRENT_DEST" ]]; then
    continue
  fi

  if python3 "$VERIFY_SCRIPT" --host "$candidate" --port 443 --timeout "$VERIFY_TIMEOUT" >/dev/null 2>&1; then
    echo "$candidate"
    exit 0
  fi
done < <(awk '{print $1}' "$BEST_DOMAINS_FILE")

echo "No valid candidates found" >&2
exit 1
