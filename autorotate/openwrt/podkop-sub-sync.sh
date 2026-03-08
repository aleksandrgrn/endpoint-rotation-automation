#!/bin/sh
set -eu

LOCK_DIR="/tmp/podkop-sub-sync.lockdir"
CONF_FILE="/etc/podkop-sub-sync.conf"
LOG_TAG="podkop-sub-sync"

log() {
  # do not log vless:// contents
  logger -t "$LOG_TAG" "$@" 2>/dev/null || true
}

# Load config if present.
# Expected variables:
#   SUB_URL="https://sub.example.com/sub/<token>"
if [ -f "$CONF_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONF_FILE"
fi

# Allow env override (e.g., for manual runs)
SUB_URL="${SUB_URL:-}"

if [ -z "$SUB_URL" ]; then
  log "missing SUB_URL (set in $CONF_FILE)"
  exit 0
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  exit 0
fi

cleanup() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

html="$(curl -fsSL --connect-timeout 10 --max-time 20 "$SUB_URL")" || {
  log "curl failed for subscription url"
  exit 0
}

one_line="$(printf '%s' "$html" | tr '\n' ' ' | sed 's/&amp;/\&/g')"

extract_links() {
  # Portable extraction: split by common HTML delimiters, then keep vless:// tokens.
  # Avoid sed hex escapes (BusyBox compatibility).
  printf '%s' "$one_line" \
    | tr '"\047<> ' '\n' \
    | grep '^vless://'
}

links="$(extract_links 2>/dev/null || true)"
if [ -z "$links" ]; then
  log "no vless links found in subscription html"
  exit 0
fi

selected=""
if printf '%s' "$links" | grep -q 'Family%20-%20Router'; then
  selected="$(printf '%s' "$links" | grep 'Family%20-%20Router' | head -n1)"
else
  if [ "$(printf '%s' "$links" | wc -l)" -eq 1 ]; then
    selected="$links"
  else
    log "multiple vless links found and no router-specific marker; abort"
    exit 0
  fi
fi

case "$selected" in
  vless://*) : ;;
  *) log "selected link is not vless:// (abort)"; exit 0 ;;
esac

case "$selected" in
  *":443"*) : ;;
  *) log "selected link has no :443 (abort)"; exit 0 ;;
esac

case "$selected" in
  *"security=reality"*) : ;;
  *) log "selected link is not reality (abort)"; exit 0 ;;
esac

case "$selected" in
  *"sni="*) : ;;
  *) log "selected link missing sni= (abort)"; exit 0 ;;
esac

case "$selected" in
  *"pbk="*) : ;;
  *) log "selected link missing pbk= (abort)"; exit 0 ;;
esac

current="$(uci -q get podkop.main.proxy_string || true)"
if [ "$current" = "$selected" ]; then
  exit 0
fi

uci set podkop.main.proxy_string="$selected"
uci commit podkop
/etc/init.d/podkop restart

updated="$(uci -q get podkop.main.proxy_string || true)"
if [ "$updated" != "$selected" ]; then
  log "uci verify failed after update"
  exit 1
fi

log "updated podkop.main.proxy_string (changed)"
exit 0
