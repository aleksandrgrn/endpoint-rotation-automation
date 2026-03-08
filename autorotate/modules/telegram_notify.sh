#!/usr/bin/env bash
set -Eeuo pipefail

# No files are written here, but keep consistent hardening defaults.
umask 077

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <html-message>" >&2
  exit 2
fi

MSG="$1"
TG_TOKEN="${TG_TOKEN:?TG_TOKEN is required}"
TG_ID="${TG_ID:?TG_ID is required}"

for attempt in 1 2 3; do
  if curl -sS --connect-timeout 5 --max-time 10 \
    -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_ID}" \
    --data-urlencode text="${MSG}" \
    -d parse_mode="HTML" >/dev/null; then
    exit 0
  fi
  sleep 1
  echo "Telegram send attempt ${attempt} failed" >&2
done

exit 1
