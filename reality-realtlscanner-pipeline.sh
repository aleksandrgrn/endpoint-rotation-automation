#!/usr/bin/env bash
set -Eeuo pipefail

# ====== DIAGNOSTICS ======
SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
trap 'echo "ERROR: ${SCRIPT_NAME}:${LINENO}: command failed: ${BASH_COMMAND}" >&2' ERR

# Run: DEBUG=1 ./reality-realtlscanner-pipeline.sh
if [[ "${DEBUG:-0}" == "1" ]]; then
  export PS4='+(${BASH_SOURCE##*/}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
  set -x
fi

# ====== CONFIG (defaults) ======
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
REPO_URL="https://github.com/XTLS/RealiTLScanner.git"
REPO_DIR="${WORKDIR}/RealiTLScanner"
BIN="${REPO_DIR}/RealiTLScanner"

ADDR_CIDR_DEFAULT="77.221.140.0/22"
THREADS_DEFAULT="20"
SCAN_TIMEOUT_DEFAULT="5"
TLS_TIMEOUT_DEFAULT="4"
TCP_TIMEOUT_DEFAULT="2"
TLS_RUNS_DEFAULT="3"
TOP_N_DEFAULT="30"

# Output files (in REPO_DIR)
UPDATE_LOG="01_update.log"
SCAN_LOG="02_scan.log"
TLS_LOG="03_tls_check.log"
DOMAINS_TXT="03_domains.txt"
DOMAINS_FILTERED_TXT="03_domains.filtered.txt"
TLS_RESULTS_CSV="03_tls_results.csv"
TLS_FAIL_LOG="03_tls_fail_reasons.tsv"
BEST_TXT="04_best_domains.txt"
XRAY_JSON_TXT="05_xray_snippet.json"
SCAN_OUT_CSV="${REPO_DIR}/aeza_scan_results.csv"

# ====== HELPERS ======
ts() { date +"%Y-%m-%d %H:%M:%S"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

prompt_default() {
  local q="$1" d="$2" a
  read -r -p "$q [$d]: " a || true
  a="$(trim "${a:-}")"
  if [ -z "$a" ]; then echo "$d"; else echo "$a"; fi
}

# ====== PRECHECK ======
# OFFLINE=1 mode: запрещены auto-update и build. Требуется заранее подготовленный бинарь.
OFFLINE="${OFFLINE:-0}"

need_cmd bash
need_cmd awk
need_cmd sed
need_cmd grep
need_cmd sort
need_cmd head
need_cmd tee
need_cmd tail
need_cmd tr
need_cmd cat
need_cmd mktemp
need_cmd timeout
need_cmd openssl
need_cmd getent
need_cmd date
need_cmd rm
need_cmd mkdir
need_cmd xargs
need_cmd paste
need_cmd wc

if [[ "$OFFLINE" != "1" ]]; then
  need_cmd git
  need_cmd go
fi

# Определяем поддержку -brief один раз корректно
if openssl s_client -help 2>&1 | grep -q -- '-brief'; then
  OPENSSL_BRIEF="-brief"
else
  OPENSSL_BRIEF=""
fi

# ====== INTERACTIVE PROFILE ======
echo "Select profile for filtering domains:"
echo "  1) РФ (ru-сервисы/популярные CDN/почты/маркетплейсы/соцсети)"
echo "  2) Международный (Google/Cloudflare/Akamai/Fastly/AWS/etc.)"
echo "  3) Свой allow-regex (ввести вручную)"
echo "  4) Без allowlist (только deny/эвристика)  [наименее строгий]"

# In OFFLINE mode systemd will provide no stdin; we still want deterministic defaults.
read -r -p "Choice [1-4]: " CHOICE || CHOICE="1"

DENY_REGEX='(^localhost$|\.local$|\.lan$|\.home$|\.internal$|\.invalid$|\.test$|\.example$|(^|\.)(duckdns\.org|mooo\.com|ignorelist\.com|ddns\.net|no-ip\.org|hopto\.org|dns-dynamic\.net)$)'
ALLOW_REGEX=""

case "${CHOICE:-1}" in
  1)
    ALLOW_REGEX='(\.ru$|\.su$|(^|\.)(yandex|ya|mail|vk|userapi|mycdn|ok|okcdn|avito|ozon|max|tinkoff|sber|gosuslugi|rambler|mts|beeline|megafon|tele2|rostelecom|1c|wildberries|wb|lamoda|kaspersky|drweb|rt|dzen)\.)'
    ;;
  2)
    ALLOW_REGEX='(\.com$|\.net$|\.org$|\.io$|\.ai$|(^|\.)(google|gstatic|googleapis|cloudflare|akamai|akamaiedge|fastly|github|microsoft|azure|windows|office|amazonaws|apple|icloud|cdn77|digitalocean|linode|ovh|hetzner|jsdelivr|unpkg)\.)'
    ;;
  3)
    read -r -p "Enter ALLOW_REGEX (extended regex for grep -E): " ALLOW_REGEX || ALLOW_REGEX=""
    ;;
  4)
    ALLOW_REGEX=""
    ;;
  *)
    echo "Unknown choice, using РФ profile."
    ALLOW_REGEX='(\.ru$|\.su$|(^|\.)(yandex|ya|mail|vk|userapi|ok|avito|ozon|max|tinkoff|sber|mts|beeline|megafon|tele2|rostelecom|wildberries|lamoda)\.)'
    ;;
esac

echo ""
echo "Config (press Enter to keep defaults):"
ADDR_CIDR="$(prompt_default    "CIDR to scan"                "${ADDR_CIDR_DEFAULT}")"
THREADS="$(prompt_default      "Parallel threads"            "${THREADS_DEFAULT}")"
SCAN_TIMEOUT="$(prompt_default "Scanner timeout (sec)"       "${SCAN_TIMEOUT_DEFAULT}")"
TCP_TIMEOUT="$(prompt_default  "TCP connect timeout (sec)"   "${TCP_TIMEOUT_DEFAULT}")"
TLS_TIMEOUT="$(prompt_default  "TLS handshake timeout (sec)" "${TLS_TIMEOUT_DEFAULT}")"
TLS_RUNS="$(prompt_default     "TLS runs per domain"         "${TLS_RUNS_DEFAULT}")"
TOP_N="$(prompt_default        "Top N best domains"          "${TOP_N_DEFAULT}")"

echo ""
echo "Profile:"
echo "  DENY_REGEX  = ${DENY_REGEX}"
echo "  ALLOW_REGEX = ${ALLOW_REGEX:-<none>}"
echo ""

# ====== SINGLE INSTANCE LOCK ======
# Защита от параллельных запусков: иначе будут гонки (rm -rf FAIL_DIR, перезапись логов/CSV).
LOCK_DIR="${WORKDIR}/.realtlscanner-pipeline.lock"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  echo "ERROR: another instance is running (lock dir exists): ${LOCK_DIR}" >&2
  exit 1
fi

cleanup() {
  if [ -n "${FAIL_DIR:-}" ] && [ -d "${FAIL_DIR:-}" ]; then
    rm -rf -- "${FAIL_DIR}" 2>/dev/null || true
  fi
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# ====== 1) SMART UPDATE (or OFFLINE) ======
mkdir -p "${WORKDIR}"

if [[ "${OFFLINE}" == "1" ]]; then
  echo "[$(ts)] OFFLINE=1: skip git update/build; using prebuilt scanner binary" >&2

  if [[ ! -x "${BIN}" ]]; then
    echo "ERROR: OFFLINE=1 but scanner binary is missing or not executable: ${BIN}" >&2
    echo "HINT: prepare scanner manually (clone/build) outside systemd, then re-run" >&2
    exit 1
  fi

  cd "${REPO_DIR}" 2>/dev/null || {
    echo "ERROR: OFFLINE=1 but REPO_DIR does not exist: ${REPO_DIR}" >&2
    exit 1
  }
else
  if [ ! -d "${REPO_DIR}/.git" ]; then
    echo "[$(ts)] Repo not found, cloning..."
    git clone "${REPO_URL}" "${REPO_DIR}"
  fi

  cd "${REPO_DIR}"

  {
    CUR_BRANCH="$(git symbolic-ref --short -q HEAD || true)"
    if [ -z "${CUR_BRANCH}" ]; then
      CUR_BRANCH="$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's#^origin/##' || true)"
    fi
    [ -n "${CUR_BRANCH}" ] || CUR_BRANCH="main"

    LOCAL_SHA="$(git rev-parse --short HEAD)"
    echo "[$(ts)] Local:  ${LOCAL_SHA}  (branch: ${CUR_BRANCH})"

    if ! git fetch origin 2>&1; then
      echo "[$(ts)] WARN: git fetch failed, continuing with local state"
    fi

    UPSTREAM="origin/${CUR_BRANCH}"
    if ! git rev-parse "${UPSTREAM}" >/dev/null 2>&1; then
      UPSTREAM="origin/HEAD"
    fi

    REMOTE_SHA="$(git rev-parse --short "${UPSTREAM}" 2>/dev/null || true)"
    [ -n "${REMOTE_SHA}" ] || REMOTE_SHA="unknown"
    echo "[$(ts)] Remote: ${REMOTE_SHA}"

    NEED_PULL=0
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse "${UPSTREAM}" 2>/dev/null || true)" ]; then
      NEED_PULL=1
    fi

    NEED_BUILD=0

    if [ "${NEED_PULL}" -eq 1 ]; then
      echo "[$(ts)] Updates available, checking changed files..."
      CHANGED="$(git diff --name-only HEAD..${UPSTREAM} 2>/dev/null || true)"

      echo "[$(ts)] Syncing to ${UPSTREAM} (hard reset)..."
      git reset --hard "${UPSTREAM}" 2>&1

      if echo "${CHANGED}" | grep -Eq '(\.go$|^go\.mod$|^go\.sum$)'; then
        NEED_BUILD=1
        echo "[$(ts)] Go sources changed -> rebuild needed"
      else
        echo "[$(ts)] No Go source changes -> skip rebuild"
      fi
    else
      echo "[$(ts)] Already up to date -> no pull"
    fi

    if [ ! -x "${BIN}" ]; then
      NEED_BUILD=1
      echo "[$(ts)] Binary missing -> rebuild needed"
    fi

    if [ "${NEED_BUILD}" -eq 1 ]; then
      echo "[$(ts)] Building (go build -ldflags=\"-s -w\" -o RealiTLScanner .) ..."
      go build -ldflags="-s -w" -o RealiTLScanner .
      echo "[$(ts)] Build OK. Binary: ${BIN}"
    else
      echo "[$(ts)] Binary is up to date, skipping build"
    fi

  } 2>&1 | tee -a "${UPDATE_LOG}"

  if [ ! -x "${BIN}" ]; then
    echo "ERROR: binary not found or not executable: ${BIN}" >&2
    exit 1
  fi
fi

# Директория для per-worker fail-файлов
# Делается уникальной на каждый запуск, чтобы параллельные запуски не мешали друг другу.
FAIL_DIR="$(mktemp -d -p "${REPO_DIR}" .tls_fail_tmp.XXXXXX)"

# FIX 3: убран ранний : > "${TLS_FAIL_LOG}" — он перезаписывается после xargs
: > "${UPDATE_LOG}"
: > "${SCAN_LOG}"
: > "${TLS_LOG}"
: > "${DOMAINS_TXT}"
: > "${DOMAINS_FILTERED_TXT}"
: > "${TLS_RESULTS_CSV}"
: > "${BEST_TXT}"
: > "${XRAY_JSON_TXT}"

# ====== 2) RUN SCAN ======
{
  echo "[$(ts)] Starting scan:"
  echo "  ${BIN} -addr ${ADDR_CIDR} -thread ${THREADS} -timeout ${SCAN_TIMEOUT} -v -out ${SCAN_OUT_CSV}"
  "${BIN}" \
    -addr    "${ADDR_CIDR}" \
    -thread  "${THREADS}" \
    -timeout "${SCAN_TIMEOUT}" \
    -v \
    -out     "${SCAN_OUT_CSV}"
  echo "[$(ts)] Scan finished. Output: ${SCAN_OUT_CSV}"
} 2>&1 | tee -a "${SCAN_LOG}"

if [ ! -s "${SCAN_OUT_CSV}" ]; then
  echo "ERROR: scan output CSV not found or empty: ${SCAN_OUT_CSV}" | tee -a "${SCAN_LOG}"
  exit 1
fi

# ====== 3) EXTRACT + FILTER DOMAINS ======
{ echo "[$(ts)] Extracting domains from ${SCAN_OUT_CSV} (column CERT_DOMAIN) ..."; } \
  | tee -a "${TLS_LOG}"

awk -F',' 'NR>1 {print $3}' "${SCAN_OUT_CSV}" \
  | sed -E 's/"//g' \
  | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
  | { grep -v '^$' || [ $? -eq 1 ]; } \
  | { grep -v '^\*\.' || [ $? -eq 1 ]; } \
  | { grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || [ $? -eq 1 ]; } \
  | sort -u \
  > "${DOMAINS_TXT}"

DOM_CNT="$(wc -l < "${DOMAINS_TXT}" | tr -d ' ')"
{ echo "[$(ts)] Domains extracted: ${DOM_CNT}"; echo "[$(ts)] Applying anti-noise filter..."; } \
  | tee -a "${TLS_LOG}"

filter_domains() {
  local in="$1" out="$2"
  awk '
    function badlabel(x){ return (x ~ /^-/ || x ~ /-$/ || x ~ /^$/) }
    function valid(s,   n,i,a){
      if (length(s) < 3) return 0
      if (s !~ /^[A-Za-z0-9.-]+$/) return 0
      if (s ~ /^\./ || s ~ /\.$/) return 0
      if (s ~ /^-/  || s ~ /-$/)  return 0
      if (s ~ /\.\./) return 0
      n=split(s,a,".")
      if (n < 2) return 0
      for (i=1;i<=n;i++){
        if (badlabel(a[i])) return 0
        if (a[i] !~ /^[A-Za-z0-9-]+$/) return 0
        if (length(a[i]) > 63) return 0
      }
      if (length(s) > 253) return 0
      return 1
    }
    { d=tolower($0); if (valid(d)) print d }
  ' "$in" \
  | { grep -vE "${DENY_REGEX}" || [ $? -eq 1 ]; } \
  | { if [ -n "${ALLOW_REGEX}" ]; then grep -E "${ALLOW_REGEX}" || [ $? -eq 1 ]; else cat; fi; } \
  | sort -u > "$out"
}

filter_domains "${DOMAINS_TXT}" "${DOMAINS_FILTERED_TXT}"

DOM_FCNT="$(wc -l < "${DOMAINS_FILTERED_TXT}" | tr -d ' ')"
{
  echo "[$(ts)] Domains after filter: ${DOM_FCNT}"
  echo "[$(ts)] Checking TCP+TLS (parallel=${THREADS}, tls_runs=${TLS_RUNS}) ..."
  echo "[$(ts)] Output CSV: ${TLS_RESULTS_CSV}"
} | tee -a "${TLS_LOG}"

# ====== 4) TCP+TLS CHECK (multi-run + median) ======
echo "domain,tcp_ok,tls_ok,tls_ok_runs,tls_median_s,ip_cnt,resolved_ipv4s" > "${TLS_RESULTS_CSV}"

check_one() {
  local d="$1"
  local ips ip_cnt tcp_ok tls_ok ok_runs med
  local times_ms=() i=0 start end diff

  # fail output file must be unique per worker; don't embed domain in filename (может быть >255 байт)
  local fail_out
  fail_out="$(mktemp "${FAIL_DIR}/fail.XXXXXX.tsv")"

  ips="$(getent ahostsv4 "$d" 2>/dev/null \
    | awk '{print $1}' | sort -u | paste -sd'|' -)"
  [ -n "$ips" ] || ips="-"

  ip_cnt="$(awk -v s="$ips" 'BEGIN{
    if (s=="-" || s=="") { print 0 }
    else { n=split(s,a,"|"); print n }
  }')"

  # TCP: домен передаётся как позиционный аргумент — не интерполируется в строку
  if timeout "$TCP_TIMEOUT" bash -c \
       'cat < /dev/null > /dev/tcp/$1/443' _ "$d" >/dev/null 2>&1; then
    tcp_ok="OK"
  else
    tcp_ok="FAIL"
    printf "%s\tTCP_CONNECT_FAIL\n" "$d" >> "${fail_out}"
  fi

  ok_runs=0
  med="-"

  if [ "$tcp_ok" = "OK" ]; then
    while [ "$i" -lt "$TLS_RUNS" ]; do
      i=$(( i + 1 ))
      start="$(date +%s%3N 2>/dev/null || echo 0)"
      if timeout "$TLS_TIMEOUT" openssl s_client \
           -connect "$d:443" \
           -servername "$d" \
           ${OPENSSL_BRIEF:+$OPENSSL_BRIEF} \
           </dev/null >/dev/null 2>&1; then
        end="$(date +%s%3N 2>/dev/null || echo 0)"
        if [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$start" != "0" ]]; then
          diff=$(( end - start ))
          times_ms+=("$diff")
        else
          times_ms+=("999999")
        fi
        ok_runs=$(( ok_runs + 1 ))
      fi
    done

    if [ "$ok_runs" -gt 0 ]; then
      med="$(printf "%s\n" "${times_ms[@]}" | sort -n | awk '
        {a[NR]=$1}
        END{
          if (NR==0){print "-"; exit}
          mid=int((NR+1)/2)
          ms=a[mid]
          printf "%d.%03d", int(ms/1000), (ms%1000)
        }')"
    fi

    # TCP прошёл, TLS нет — логируем причину (только для FAIL)
    if [ "$ok_runs" -eq 0 ]; then
      local tls_err
      tls_err="$(timeout "$TLS_TIMEOUT" openssl s_client \
        -connect "$d:443" \
        -servername "$d" \
        ${OPENSSL_BRIEF:+$OPENSSL_BRIEF} \
        </dev/null 2>&1 | tail -n 3 | tr '\n' ' ')"
      # FIX 2: явный префикс TLS_FAIL: для удобного грепа
      printf "%s\tTLS_FAIL: %s\n" "$d" "${tls_err:-(no output)}" >> "${fail_out}"
    fi
  fi

  [ "$ok_runs" -gt 0 ] && tls_ok="OK" || tls_ok="FAIL"

  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$d" "$tcp_ok" "$tls_ok" "$ok_runs" "$med" "$ip_cnt" "$ips"
}

export -f check_one
export TCP_TIMEOUT TLS_TIMEOUT TLS_RUNS OPENSSL_BRIEF FAIL_DIR

xargs -a "${DOMAINS_FILTERED_TXT}" -r -n 1 -P "${THREADS}" \
  bash -c 'check_one "$@"' _ \
  >> "${TLS_RESULTS_CSV}"

# Собираем все per-worker файлы в один после завершения параллели
# FIX 3: заголовок пишется только здесь — нет дублирования
printf "domain\treason\n" > "${TLS_FAIL_LOG}"
shopt -s nullglob
fail_files=("${FAIL_DIR}"/*.tsv)
shopt -u nullglob
if ((${#fail_files[@]})); then
  cat "${fail_files[@]}" | sort -u >> "${TLS_FAIL_LOG}"
fi

TCP_OK_COUNT="$(awk -F',' 'NR>1 && $2=="OK" {c++} END{print c+0}' "${TLS_RESULTS_CSV}")"
TLS_OK_COUNT="$(awk -F',' 'NR>1 && $3=="OK" {c++} END{print c+0}' "${TLS_RESULTS_CSV}")"
FAIL_REASON_COUNT="$(awk 'NR>1' "${TLS_FAIL_LOG}" | wc -l | tr -d ' ')"
{
  echo "[$(ts)] Checks done. TCP_OK=${TCP_OK_COUNT} TLS_OK=${TLS_OK_COUNT} (TLS runs=${TLS_RUNS})"
  echo "[$(ts)] FAIL reasons logged: ${FAIL_REASON_COUNT} -> ${TLS_FAIL_LOG}"
} | tee -a "${TLS_LOG}"

# ====== 5) PICK BEST for REALITY dest ======
{
  echo "[$(ts)] Selecting best ${TOP_N} domains for REALITY dest:"
  echo "  priority: tcp_ok=OK > tls_ok=OK > more ok_runs > more ip_cnt > lower median"
} | tee -a "${TLS_LOG}"

# CSV columns: domain,tcp_ok,tls_ok,tls_ok_runs,tls_median_s,ip_cnt,resolved_ipv4s
#              $1     $2     $3     $4           $5           $6     $7
awk -F',' '
  NR==1 {next}
  {
    d=$1; tcp=$2; tls=$3; runs=$4; med=$5; ipcnt=$6; ips=$7

    key_tcp   = (tcp=="OK") ? 0 : 1
    key_tls   = (tls=="OK") ? 0 : 1
    med_s     = (med==""   || med=="-") ? 999999 : (med+0)
    ipcnt_n   = (ipcnt=="")             ? 0       : (ipcnt+0)
    key_runs  = 1000 - runs
    key_ipcnt = 1000 - ipcnt_n

    print key_tcp "," key_tls "," key_runs "," key_ipcnt "," med_s \
          "," d "," tcp "," tls "," runs "," med "," ipcnt "," ips
  }
' "${TLS_RESULTS_CSV}" \
| sort -t',' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n \
| head -n "${TOP_N}" \
| awk -F',' -v RUNS="${TLS_RUNS}" '{
    d=$6; tcp=$7; tls=$8; runs=$9; med=$10; ipcnt=$11; ips=$12
    printf "%-40s  TCP:%-4s  TLS:%-4s  runs=%s/%s  med=%ss  ips_cnt=%-2s  ips=%s\n",
           d, tcp, tls, runs, RUNS, med, ipcnt, ips
  }' \
> "${BEST_TXT}"

BEST_COUNT="$(wc -l < "${BEST_TXT}" | tr -d ' ')"
{ echo "[$(ts)] Done. Best domains saved: ${BEST_COUNT}"; } | tee -a "${TLS_LOG}"

# ====== 6) XRAY CONFIG SNIPPET ======
TOP1_DOMAIN="$(awk 'NR==1{print $1}' "${BEST_TXT}" 2>/dev/null || true)"
TOP3_DOMAINS="$(awk 'NR<=3{print $1}' "${BEST_TXT}" 2>/dev/null || true)"

if [ -n "${TOP1_DOMAIN}" ]; then
  SN_JSON="$(echo "${TOP3_DOMAINS}" | awk '
    { a[NR]=$1 }
    END {
      for (i=1; i<=NR; i++) {
        comma = (i<NR) ? "," : ""
        printf "    \"%s\"%s\n", a[i], comma
      }
    }')"

  cat > "${XRAY_JSON_TXT}" <<EOF
// === REALITY dest snippet (вставь в inbounds -> streamSettings -> realitySettings) ===
// TOP-1 используется как dest; TOP-3 как serverNames.
// Остальные поля (privateKey, shortIds) оставь своими.
// Совет: для стабильности можно оставить только один serverNames = dest.

"realitySettings": {
  "show": false,
  "dest": "${TOP1_DOMAIN}:443",
  "xver": 0,
  "serverNames": [
${SN_JSON}
  ]
}
EOF

  echo ""
  echo "=== XRAY CONFIG SNIPPET (${REPO_DIR}/${XRAY_JSON_TXT}) ==="
  cat "${REPO_DIR}/${XRAY_JSON_TXT}"
else
  {
    echo "[$(ts)] WARN: no OK domains found — BEST_TXT is empty."
    echo "[$(ts)] Hints:"
    echo "[$(ts)]   - попробуй профиль 4 (без allowlist)"
    echo "[$(ts)]   - увеличь TLS_TIMEOUT / TCP_TIMEOUT"
    echo "[$(ts)]   - уменьши TLS_RUNS до 1"
    echo "[$(ts)]   - проверь, что VPS вообще достигает 443 порта наружу"
    echo "[$(ts)]   - смотри причины отказов: ${REPO_DIR}/${TLS_FAIL_LOG}"
  } | tee -a "${TLS_LOG}"
fi

{
  echo ""
  echo "Files:"
  echo "  ${REPO_DIR}/${UPDATE_LOG}"
  echo "  ${REPO_DIR}/${SCAN_LOG}"
  echo "  ${REPO_DIR}/${TLS_LOG}"
  echo "  ${SCAN_OUT_CSV}"
  echo "  ${REPO_DIR}/${DOMAINS_TXT}"
  echo "  ${REPO_DIR}/${DOMAINS_FILTERED_TXT}"
  echo "  ${REPO_DIR}/${TLS_RESULTS_CSV}"
  echo "  ${REPO_DIR}/${TLS_FAIL_LOG}"
  echo "  ${REPO_DIR}/${BEST_TXT}"
  echo "  ${REPO_DIR}/${XRAY_JSON_TXT}"
} | tee -a "${TLS_LOG}"

echo ""
echo "=== TOP ${TOP_N} BEST DOMAINS (for REALITY dest) ==="
cat "${REPO_DIR}/${BEST_TXT}"
