#!/usr/bin/env bash
# Soviez ERP — production onboarding wizard (Ubuntu/Debian)
#
# Modes:
#   ./soviez.sh            | --init    Host environment bootstrap (apt, Docker, Nginx, Certbot, UFW)
#   ./soviez.sh --new                  Provision isolated multi-tenant instance + DNS/SSL/addons
#   ./soviez.sh --formsetup            Resume / heal the latest half-configured tenant (idempotent)
#   ./soviez.sh --formssl [domain]     Diagnose / repair tenant HTTPS (LE or self-signed Cloudflare Full)
#   ./soviez.sh --list                 List tenants (index, domain, docker status)
#   ./soviez.sh --backup <tenant> <db> Space-checked DB+filestore archive → /var/soviez/backups
#   ./soviez.sh --backup-list          Inventory existing backup archives
#   ./soviez.sh --stage <tenant> <db>  Clone <db> → stage DB + filestore, then neutralize
#   ./soviez.sh --dropstage <tenant> <db>  Drop neutralized DB + filestore (safe shield)
#   ./soviez.sh --reset-pass <tenant> <db> <user> <pass>  Odoo-compliant admin password reset
#   ./soviez.sh --change-domain <tenant>   Repoint tenant DNS/Nginx/HTTPS to a new domain
#   ./soviez.sh --monitor              Live docker stats for running soviez-* containers
#   ./soviez.sh --logs <tenant>        Stream docker logs for the tenant web container
#   ./soviez.sh --update               Pull soviez/soviez-erp:latest and recycle web runners
#   ./soviez.sh --formworkers <tenant>   Auto-tune Odoo workers, PG buffers, Docker limits
#   ./soviez.sh --recoverdbpass        Rotate Database Master Password (primary / indexed via env)
#
# Logs: /var/log/soviez_setup.log (verbose); terminal shows clean status UI only.
set -euo pipefail

readonly APP_IMAGE="soviez/soviez-erp:latest"
readonly DB_IMAGE="postgres:16"
readonly UPGRADE_MODULES="base,local_license_guard,mail,web,web_enterprise,soviez_web_ui"
readonly PORT_SCAN_MAX=8999
readonly PRIMARY_PORT_START=8069
readonly MULTI_PORT_START=8073
# Host layout: /soviez/soviez_web[_N]/addons  →  container: /root/custom_addons
readonly SOVIEZ_HOST_ROOT="/soviez"
readonly CUSTOM_ADDONS_CONTAINER_PATH="/root/custom_addons"
readonly BACKUP_ROOT="/var/soviez/backups"
readonly BACKUP_SAFETY_MARGIN_BYTES=$((5 * 1024 * 1024 * 1024))
readonly SOVIEZ_VOLUME_ROOT="/var/soviez/volumes"
readonly RESOURCE_UTIL_WARN_PCT=80
readonly RESOURCE_SYSTEM_REQUIREMENTS_URL="https://www.soviez.com/docs/system-requirements#size-production-server"
LOG_FILE="/var/log/soviez_setup.log"
readonly NGINX_LIMITS_CONF="/etc/nginx/conf.d/soviez_limits.conf"

# Mutable topology (overridden by apply_topology_*)
ENV_FILE=".soviez.env"
NETWORK_NAME="soviez_network"
DB_CONTAINER="soviez-db"
WEB_CONTAINER="soviez-web"
DB_VOLUME="soviez_db_data"
FILESTORE_VOLUME="soviez_filestore"
INSTANCE_INDEX=""
PORT_SCAN_START="${PRIMARY_PORT_START}"
CUSTOM_ADDONS_HOST_PATH=""
TENANT_DOMAIN=""
FORMSSL_DOMAIN=""
# Set by provision_tenant_https / --formssl: letsencrypt | selfsigned
SSL_STATUS=""
# Public IPv4 used for force-hijack Nginx listen ${PUBLIC_IP}:80/443
PUBLIC_IP=""
LAST_HTTPS_CODE=""
# Staging / ops mode arguments
STAGE_TENANT_REF=""
STAGE_SOURCE_DB=""
DROPSTAGE_TENANT_REF=""
DROPSTAGE_DB=""
BACKUP_TENANT_REF=""
BACKUP_DB=""
RESET_TENANT_REF=""
RESET_DB=""
RESET_USERNAME=""
RESET_PASSWORD=""
CHANGE_DOMAIN_TENANT_REF=""
LOGS_TENANT_REF=""
FORMWORKERS_TENANT_REF=""
# Resource tuning outputs (set by compute_allocation_for_tenant)
WORKERS=""
LIMIT_SOFT_BYTES=""
LIMIT_HARD_BYTES=""
PG_SHARED_MB=""
PG_EFFECTIVE_MB=""
DOCKER_MEM_MB=""
DOCKER_CPUS=""
ALLOC_RAM_MB=""
ALLOC_CORES=""
AUTO_TUNE_ON_NEW=0
readonly STAGE_DB_NAME="stage"
readonly DB_APP_USER="soviez"

# ---------------------------------------------------------------------------
# Colors / UI
# ---------------------------------------------------------------------------
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_DIM=$'\033[2m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[0;33m'
readonly C_RED=$'\033[0;31m'
readonly C_CYAN=$'\033[0;36m'
readonly C_BLUE=$'\033[0;34m'

# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------
MODE="init"
strip_trailing_hyphens() {
  local s="$1"
  while [[ "${s}" == *- ]]; do
    s="${s%-}"
  done
  printf '%s\n' "${s}"
}

for arg in "$@"; do
  case "${arg}" in
    --init)
      MODE="init"
      ;;
    --update)
      MODE="update"
      ;;
    --new)
      MODE="new"
      ;;
    --formsetup)
      MODE="formsetup"
      ;;
    --formssl)
      MODE="formssl"
      ;;
    --stage)
      MODE="stage"
      ;;
    --dropstage)
      MODE="dropstage"
      ;;
    --backup-list)
      MODE="backup-list"
      ;;
    --backup)
      MODE="backup"
      ;;
    --reset-pass)
      MODE="reset-pass"
      ;;
    --change-domain)
      MODE="change-domain"
      ;;
    --monitor)
      MODE="monitor"
      ;;
    --logs)
      MODE="logs"
      ;;
    --list)
      MODE="list"
      ;;
    --recoverdbpass)
      MODE="recover"
      ;;
    --formworkers)
      MODE="formworkers"
      ;;
    -h|--help)
      cat <<'USAGE'
Soviez ERP — production onboarding wizard

Usage:
  ./soviez.sh [--init]                       Bootstrap host (apt, Docker, Nginx, Certbot, UFW)
  ./soviez.sh --new                          Provision a new isolated tenant (domain + SSL + addons)
  ./soviez.sh --list                         List all tenants (domain + Docker status)
  ./soviez.sh --backup <tenant> <db>         Space-checked DB + filestore backup (5 GB host buffer)
  ./soviez.sh --backup-list                  List archives under /var/soviez/backups
  ./soviez.sh --formsetup                    Resume / heal latest half-configured tenant
  ./soviez.sh --formssl [domain]             Diagnose / repair HTTPS (Let's Encrypt or self-signed)
  ./soviez.sh --stage <tenant> <source_db>   Clone source_db → stage (+ filestore), neutralize
  ./soviez.sh --dropstage <tenant> <db>      Drop a neutralized DB + filestore (safe shield)
  ./soviez.sh --reset-pass <tenant> <db> <user> <password>
                                             Odoo-compliant password reset (hashed write)
  ./soviez.sh --change-domain <tenant>       Repoint tenant to a new domain (DNS + Nginx + SSL)
  ./soviez.sh --monitor                      Live docker stats for running soviez-* containers
  ./soviez.sh --logs <tenant>                Follow tenant web container logs
  ./soviez.sh --update                       Pull latest ERP image and recycle web containers
  ./soviez.sh --formworkers <tenant>         Tune Odoo workers, PostgreSQL buffers, Docker limits
  ./soviez.sh --recoverdbpass                Rotate Database Master Password
  ./soviez.sh --help                         Show this help

Tenant refs:
  soviez-web-1 | soviez_web_1 | 1 | soviez-web (legacy primary)

Examples:
  sudo ./soviez.sh --list
  sudo ./soviez.sh --backup 2 production
  sudo ./soviez.sh --backup-list
  sudo ./soviez.sh --stage soviez-web-1 production
  sudo ./soviez.sh --dropstage soviez-web-1 stage
  sudo ./soviez.sh --reset-pass 1 production admin 'NewSecret!'
  sudo ./soviez.sh --change-domain 2
  sudo ./soviez.sh --monitor
  sudo ./soviez.sh --logs soviez-web-1
  sudo ./soviez.sh --formworkers soviez-web-1

Images:
  soviez/soviez-erp:latest
  postgres:16

Verbose log:
  /var/log/soviez_setup.log
USAGE
      exit 0
      ;;
    -*)
      echo "[ERROR] Unknown argument: ${arg}" >&2
      echo "[ERROR] Try: ./soviez.sh --help" >&2
      exit 1
      ;;
    *)
      clean_arg="$(strip_trailing_hyphens "${arg}")"
      if [[ "${MODE}" == "formssl" && -z "${FORMSSL_DOMAIN}" ]]; then
        FORMSSL_DOMAIN="${clean_arg}"
      elif [[ "${MODE}" == "stage" && -z "${STAGE_TENANT_REF}" ]]; then
        STAGE_TENANT_REF="${clean_arg}"
      elif [[ "${MODE}" == "stage" && -z "${STAGE_SOURCE_DB}" ]]; then
        STAGE_SOURCE_DB="${clean_arg}"
      elif [[ "${MODE}" == "dropstage" && -z "${DROPSTAGE_TENANT_REF}" ]]; then
        DROPSTAGE_TENANT_REF="${clean_arg}"
      elif [[ "${MODE}" == "dropstage" && -z "${DROPSTAGE_DB}" ]]; then
        DROPSTAGE_DB="${clean_arg}"
      elif [[ "${MODE}" == "backup" && -z "${BACKUP_TENANT_REF}" ]]; then
        BACKUP_TENANT_REF="${clean_arg}"
      elif [[ "${MODE}" == "backup" && -z "${BACKUP_DB}" ]]; then
        BACKUP_DB="${clean_arg}"
      elif [[ "${MODE}" == "reset-pass" && -z "${RESET_TENANT_REF}" ]]; then
        RESET_TENANT_REF="${clean_arg}"
      elif [[ "${MODE}" == "reset-pass" && -z "${RESET_DB}" ]]; then
        RESET_DB="${clean_arg}"
      elif [[ "${MODE}" == "reset-pass" && -z "${RESET_USERNAME}" ]]; then
        # Do not strip hyphens from username/password payloads.
        RESET_USERNAME="${arg}"
      elif [[ "${MODE}" == "reset-pass" && -z "${RESET_PASSWORD}" ]]; then
        RESET_PASSWORD="${arg}"
      elif [[ "${MODE}" == "change-domain" && -z "${CHANGE_DOMAIN_TENANT_REF}" ]]; then
        CHANGE_DOMAIN_TENANT_REF="${clean_arg}"
      elif [[ "${MODE}" == "logs" && -z "${LOGS_TENANT_REF}" ]]; then
        LOGS_TENANT_REF="${clean_arg}"
      elif [[ "${MODE}" == "formworkers" && -z "${FORMWORKERS_TENANT_REF}" ]]; then
        FORMWORKERS_TENANT_REF="${clean_arg}"
      else
        echo "[ERROR] Unknown argument: ${arg}" >&2
        echo "[ERROR] Try: ./soviez.sh --help" >&2
        exit 1
      fi
      ;;
  esac
done

umask 077

# ---------------------------------------------------------------------------
# Logging → file; clean UI → terminal
# ---------------------------------------------------------------------------
ensure_log_file() {
  # Prefer /var/log when root; otherwise fall back to instance ledger / tmp.
  if [[ "${EUID}" -eq 0 ]]; then
    touch "${LOG_FILE}" 2>/dev/null || true
    chmod 640 "${LOG_FILE}" 2>/dev/null || true
    return 0
  fi
  if [[ -d "${HOST_SOVIEZ_DIR:-}" ]] || mkdir -p "${HOST_SOVIEZ_DIR:-${HOME}/.soviez}" 2>/dev/null; then
    LOG_FILE="${HOST_SOVIEZ_DIR:-${HOME}/.soviez}/soviez_setup.log"
  else
    LOG_FILE="/tmp/soviez_setup.log"
  fi
  touch "${LOG_FILE}" 2>/dev/null || true
}

log_file() {
  local ts
  ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '[%s] %s\n' "${ts}" "$*" >> "${LOG_FILE}" 2>/dev/null || true
}

ui_info()  { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; log_file "INFO  $*"; }
ui_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}   $*"; log_file "OK    $*"; }
ui_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; log_file "WARN  $*"; }
ui_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; log_file "ERROR $*"; }
ui_wait()  { echo -e "${C_BLUE}[WAIT]${C_RESET} $*"; log_file "WAIT  $*"; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    ui_error "This mode requires root. Re-run with: sudo ./soviez.sh $*"
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    ui_error "Required command not found: $1"
    exit 1
  fi
}

# Spinner + silent command runner (stdout/stderr → log)
show_progress() {
  local message="$1"
  shift
  local -a cmd=("$@")
  local spin='|/-\\'
  local i=0
  local pid
  local rc=0

  ensure_log_file
  ui_wait "${message}"
  log_file "EXEC  ${cmd[*]}"

  # Run in a subshell so shell functions work; keep spinner on TTY.
  (
    "${cmd[@]}"
  ) >>"${LOG_FILE}" 2>&1 &
  pid=$!

  if [[ -t 1 ]]; then
    while kill -0 "${pid}" 2>/dev/null; do
      printf '\r%s[WAIT]%s %s %s' "${C_BLUE}" "${C_RESET}" "${message}" "${spin:i++%${#spin}:1}"
      sleep 0.12
    done
    printf '\r\033[K'
  fi

  set +e
  wait "${pid}"
  rc=$?
  set -e

  if (( rc == 0 )); then
    ui_ok "${message}"
  else
    ui_error "${message} (failed — see ${LOG_FILE})"
  fi
  return "${rc}"
}

run_quiet() {
  log_file "EXEC  $*"
  "$@" >>"${LOG_FILE}" 2>&1
}

print_border_box() {
  local title="$1"
  shift
  local line
  echo ""
  echo -e "${C_BOLD}${C_CYAN}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}║${C_RESET}  ${C_BOLD}${title}${C_RESET}"
  echo -e "${C_BOLD}${C_CYAN}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
  for line in "$@"; do
    echo -e "${C_BOLD}${C_CYAN}║${C_RESET}  ${line}"
  done
  echo -e "${C_BOLD}${C_CYAN}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
  echo ""
}

print_green_success() {
  echo ""
  echo -e "${C_GREEN}${C_BOLD}==============================================================${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}  $*${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}==============================================================${C_RESET}"
  echo ""
}

print_master_password_alert() {
  local password="$1"
  local headline="${2:-DATABASE MASTER PASSWORD}"
  echo ""
  echo -e "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
  echo -e "${C_RED}${C_BOLD}!!  ${headline}${C_RESET}"
  echo -e "${C_RED}${C_BOLD}!!  ${password}${C_RESET}"
  echo -e "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
  echo -e "${C_RED}Copy and vault this password now. Required for the Web Database Manager.${C_RESET}"
  echo -e "${C_DIM}Recover later: sudo ./soviez.sh --recoverdbpass${C_RESET}"
  echo ""
}

# ---------------------------------------------------------------------------
# Paths / topology
# ---------------------------------------------------------------------------
resolve_instance_root() {
  if [[ -n "${SOVIEZ_INSTANCE_ROOT:-}" ]]; then
    printf '%s\n' "${SOVIEZ_INSTANCE_ROOT}"
    return 0
  fi
  if [[ -d /root && -w /root ]]; then
    printf '%s\n' "/root"
    return 0
  fi
  printf '%s\n' "$(pwd)"
}

resolve_host_soviez_dir() {
  if [[ -n "${SOVIEZ_HOST_LEDGER_DIR:-}" ]]; then
    printf '%s\n' "${SOVIEZ_HOST_LEDGER_DIR}"
    return 0
  fi
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "${HOME}/.soviez"
    return 0
  fi
  if [[ -d /root ]]; then
    printf '%s\n' "/root/.soviez"
    return 0
  fi
  printf '%s\n' "$(pwd)/.soviez"
}

INSTANCE_ROOT="$(resolve_instance_root)"
HOST_SOVIEZ_DIR="$(resolve_host_soviez_dir)"

ensure_host_ledger_dir() {
  mkdir -p "${HOST_SOVIEZ_DIR}"
  chmod 700 "${HOST_SOVIEZ_DIR}"
  log_file "Host ledger ready: ${HOST_SOVIEZ_DIR}"
}

is_port_busy() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
      return 0
    fi
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
      return 0
    fi
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
      return 0
    fi
    return 1
  fi
  if (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

find_free_host_port() {
  local start="${1:-${PORT_SCAN_START}}"
  local port="${start}"
  while (( port <= PORT_SCAN_MAX )); do
    if is_port_busy "${port}"; then
      log_file "Port ${port} busy — probing next"
      port=$((port + 1))
    else
      echo "${port}"
      return 0
    fi
  done
  ui_error "No free TCP port in range ${start}-${PORT_SCAN_MAX}."
  return 1
}

generate_mac() {
  python3 - <<'PY'
import secrets
octets = [secrets.randbelow(256) for _ in range(3)]
print("02:42:ac:" + ":".join(f"{b:02x}" for b in octets))
PY
}

generate_password() {
  python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(32)))
PY
}

persist_env_key() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "${ENV_FILE}" ]]; then
    grep -v "^${key}=" "${ENV_FILE}" > "${tmp}" || true
  else
    : > "${tmp}"
  fi
  echo "${key}=${value}" >> "${tmp}"
  mv "${tmp}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
}

load_env_file() {
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
}

container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$1"
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$1"
}

# Canonical host drop-zone for custom modules (multi-instance under /soviez).
canonical_custom_addons_host_path() {
  if [[ -n "${INSTANCE_INDEX}" ]]; then
    printf '%s\n' "${SOVIEZ_HOST_ROOT}/soviez_web_${INSTANCE_INDEX}/addons"
  else
    printf '%s\n' "${SOVIEZ_HOST_ROOT}/soviez_web/addons"
  fi
}

legacy_custom_addons_host_path() {
  if [[ -n "${INSTANCE_INDEX}" ]]; then
    printf '%s\n' "/etc/soviez_web_${INSTANCE_INDEX}/addons"
  else
    printf '%s\n' "/etc/soviez_web/addons"
  fi
}

# Resolve CUSTOM_ADDONS_HOST_PATH, migrating legacy /etc/soviez_web* trees when found.
resolve_custom_addons_host_path() {
  local canonical legacy current
  canonical="$(canonical_custom_addons_host_path)"
  legacy="$(legacy_custom_addons_host_path)"
  current="${CUSTOM_ADDONS_HOST_PATH:-${SOVIEZ_CUSTOM_ADDONS_HOST:-}}"

  if [[ -z "${current}" ]]; then
    current="${canonical}"
  elif [[ "${current}" == /etc/soviez_web* ]]; then
    current="${canonical}"
  fi

  CUSTOM_ADDONS_HOST_PATH="${current}"

  # One-shot migrate: move legacy /etc drop-zone into the /soviez tree.
  if [[ -d "${legacy}" && "${legacy}" != "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    mkdir -p "${CUSTOM_ADDONS_HOST_PATH}"
    if [[ -z "$(ls -A "${CUSTOM_ADDONS_HOST_PATH}" 2>/dev/null || true)" ]]; then
      # Move module trees; keep a marker so operators know the old path was vacated.
      shopt -s dotglob nullglob
      local item
      for item in "${legacy}"/*; do
        mv "${item}" "${CUSTOM_ADDONS_HOST_PATH}/" 2>/dev/null || \
          cp -a "${item}" "${CUSTOM_ADDONS_HOST_PATH}/"
      done
      shopt -u dotglob nullglob
    fi
    log_file "Migrated custom addons ${legacy} → ${CUSTOM_ADDONS_HOST_PATH}" 2>/dev/null || true
  fi

  # Keep env sheets pointing at the canonical /soviez layout + container mount.
  if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    if [[ "${SOVIEZ_CUSTOM_ADDONS_HOST:-}" != "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
      persist_env_key "SOVIEZ_CUSTOM_ADDONS_HOST" "${CUSTOM_ADDONS_HOST_PATH}" 2>/dev/null || true
    fi
    if [[ "${SOVIEZ_CUSTOM_ADDONS_MOUNT:-}" != "${CUSTOM_ADDONS_CONTAINER_PATH}" ]]; then
      persist_env_key "SOVIEZ_CUSTOM_ADDONS_MOUNT" "${CUSTOM_ADDONS_CONTAINER_PATH}" 2>/dev/null || true
    fi
  fi
  SOVIEZ_CUSTOM_ADDONS_HOST="${CUSTOM_ADDONS_HOST_PATH}"
  SOVIEZ_CUSTOM_ADDONS_MOUNT="${CUSTOM_ADDONS_CONTAINER_PATH}"
}

apply_topology_primary() {
  ENV_FILE="$(pwd)/.soviez.env"
  if [[ -f "${INSTANCE_ROOT}/.soviez.env" ]]; then
    ENV_FILE="${INSTANCE_ROOT}/.soviez.env"
  elif [[ ! -f "${ENV_FILE}" && -f ".soviez.env" ]]; then
    ENV_FILE="$(pwd)/.soviez.env"
  fi
  NETWORK_NAME="soviez_network"
  DB_CONTAINER="soviez-db"
  WEB_CONTAINER="soviez-web"
  DB_VOLUME="soviez_db_data"
  FILESTORE_VOLUME="soviez_filestore"
  INSTANCE_INDEX=""
  CUSTOM_ADDONS_HOST_PATH="$(canonical_custom_addons_host_path)"
  PORT_SCAN_START="${PRIMARY_PORT_START}"
}

apply_topology_indexed() {
  local index="$1"
  INSTANCE_INDEX="${index}"
  ENV_FILE="${INSTANCE_ROOT}/.soviez_${index}.env"
  NETWORK_NAME="soviez_network_${index}"
  DB_CONTAINER="soviez-db-${index}"
  WEB_CONTAINER="soviez-web-${index}"
  DB_VOLUME="soviez_db_data_${index}"
  FILESTORE_VOLUME="soviez_filestore_${index}"
  CUSTOM_ADDONS_HOST_PATH="$(canonical_custom_addons_host_path)"
  PORT_SCAN_START="${MULTI_PORT_START}"
}

find_next_instance_index() {
  local max=0
  local path base num

  shopt -s nullglob
  for path in \
      "${INSTANCE_ROOT}"/.soviez_*.env \
      "$(pwd)"/.soviez_*.env; do
    [[ -f "${path}" ]] || continue
    base="$(basename "${path}")"
    if [[ "${base}" =~ ^\.soviez_([0-9]+)\.env$ ]]; then
      num="${BASH_REMATCH[1]}"
      if (( num > max )); then
        max="${num}"
      fi
    fi
  done
  shopt -u nullglob

  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" =~ ^soviez-web-([0-9]+)$ ]]; then
      num="${BASH_REMATCH[1]}"
      if (( num > max )); then
        max="${num}"
      fi
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)

  if (( max >= 1 )); then
    echo $((max + 1))
  else
    echo 1
  fi
}

# Highest existing indexed env sheet (0 = none). Does not +1.
find_highest_instance_index() {
  local max=0
  local path base num

  shopt -s nullglob
  for path in \
      "${INSTANCE_ROOT}"/.soviez_*.env \
      "$(pwd)"/.soviez_*.env; do
    [[ -f "${path}" ]] || continue
    base="$(basename "${path}")"
    if [[ "${base}" =~ ^\.soviez_([0-9]+)\.env$ ]]; then
      num="${BASH_REMATCH[1]}"
      if (( num > max )); then
        max="${num}"
      fi
    fi
  done
  shopt -u nullglob
  echo "${max}"
}

# True when domain Nginx vhost, 443 listener, enabled symlink, and/or SSL material look unfinished.
tenant_proxy_incomplete() {
  local domain="$1"
  local site_file="/etc/nginx/sites-available/soviez-${domain}.conf"
  local enabled_link="/etc/nginx/sites-enabled/soviez-${domain}.conf"
  local le_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local ss_cert="/etc/ssl/certs/soviez-${domain}.crt"

  [[ -z "${domain}" ]] && return 0
  [[ ! -f "${site_file}" ]] && return 0
  [[ ! -e "${enabled_link}" ]] && return 0
  # Incomplete if vhost lacks an explicit public-IP :443 bind (legacy catch-all loses to Virtualmin).
  if ! grep -Eq "listen[[:space:]]+${PUBLIC_IP:-[0-9.]+}:443|listen[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:443" "${site_file}" 2>/dev/null; then
    if ! grep -Eq 'listen[[:space:]]+[^;]*443' "${site_file}" 2>/dev/null; then
      return 0
    fi
    # Generic listen 443 without address is treated as incomplete (Virtualmin hijack risk).
    if grep -Eq 'listen[[:space:]]+443([[:space:]]|;|$)' "${site_file}" 2>/dev/null \
        && ! grep -Eq 'listen[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:443' "${site_file}" 2>/dev/null; then
      return 0
    fi
  fi
  # Incomplete only if neither LE nor self-signed material exists.
  if [[ ! -f "${le_cert}" && ! -f "${ss_cert}" ]]; then
    return 0
  fi
  return 1
}

# Prefer highest half-configured tenant; else newest env sheet.
select_formsetup_index() {
  local max path domain
  local i
  local site_incomplete

  max="$(find_highest_instance_index)"
  if (( max < 1 )); then
    echo 0
    return 0
  fi

  for (( i = max; i >= 1; i-- )); do
    path=""
    for candidate in "${INSTANCE_ROOT}/.soviez_${i}.env" "$(pwd)/.soviez_${i}.env"; do
      if [[ -f "${candidate}" ]]; then
        path="${candidate}"
        break
      fi
    done
    [[ -n "${path}" ]] || continue

    domain="$(grep -E '^SOVIEZ_TENANT_DOMAIN=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    site_incomplete=0
    if tenant_proxy_incomplete "${domain}"; then
      site_incomplete=1
    fi
    if (( site_incomplete == 1 )) \
        || ! container_exists "soviez-db-${i}" \
        || ! container_running "soviez-db-${i}" \
        || ! container_exists "soviez-web-${i}" \
        || ! container_running "soviez-web-${i}"; then
      log_file "formsetup: selected incomplete index=${i} domain=${domain:-?} env=${path}"
      echo "${i}"
      return 0
    fi
  done

  log_file "formsetup: no incomplete tenant — resuming highest index=${max}"
  echo "${max}"
}

# ---------------------------------------------------------------------------
# Docker / DB / web lifecycle (shared by --new / --formsetup / --update / --recover)
# ---------------------------------------------------------------------------
docker_network_exists() {
  docker network inspect "$1" >/dev/null 2>&1
}

docker_volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

ensure_network_and_volumes() {
  if docker_network_exists "${NETWORK_NAME}"; then
    log_file "Network ${NETWORK_NAME} already exists"
  else
    docker network create "${NETWORK_NAME}" >>"${LOG_FILE}" 2>&1
  fi
  if docker_volume_exists "${DB_VOLUME}"; then
    log_file "Volume ${DB_VOLUME} already exists"
  else
    docker volume create "${DB_VOLUME}" >/dev/null
  fi
  if docker_volume_exists "${FILESTORE_VOLUME}"; then
    log_file "Volume ${FILESTORE_VOLUME} already exists"
  else
    docker volume create "${FILESTORE_VOLUME}" >/dev/null
  fi
}

# Idempotent resume path with tidy terminal OK lines (used by --formsetup).
resume_network_and_volumes() {
  ui_wait "Checking Docker network and volumes for ${NETWORK_NAME}..."
  local created=0
  if docker_network_exists "${NETWORK_NAME}"; then
    log_file "Network ${NETWORK_NAME} already present"
  else
    docker network create "${NETWORK_NAME}" >>"${LOG_FILE}" 2>&1
    created=1
  fi
  if docker_volume_exists "${DB_VOLUME}"; then
    log_file "Volume ${DB_VOLUME} already present"
  else
    docker volume create "${DB_VOLUME}" >/dev/null
    created=1
  fi
  if docker_volume_exists "${FILESTORE_VOLUME}"; then
    log_file "Volume ${FILESTORE_VOLUME} already present"
  else
    docker volume create "${FILESTORE_VOLUME}" >/dev/null
    created=1
  fi
  if (( created == 0 )); then
    ui_ok "Volumes already present"
  else
    ui_ok "Network and volumes ready"
  fi
}

wait_for_postgres() {
  local i
  for i in $(seq 1 45); do
    if docker exec "${DB_CONTAINER}" pg_isready -U soviez -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  ui_error "PostgreSQL did not become ready. Inspect: docker logs ${DB_CONTAINER}"
  return 1
}

# Intelligent Auto-Configuration & Resource Tuning Engine
# ===========================================================================

host_total_ram_mb() {
  awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null \
    || free -m | awk '/^Mem:/ { print $2 }'
}

host_total_cpu_cores() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2
}

tenant_odoo_conf_path() {
  printf '%s/%s/conf/odoo.conf\n' "${SOVIEZ_VOLUME_ROOT}" "${WEB_CONTAINER}"
}

tenant_runtime_conf_dir() {
  printf '%s/%s/conf\n' "${SOVIEZ_VOLUME_ROOT}" "${WEB_CONTAINER}"
}

conf_get_option() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 1
  awk -v k="${key}" '
    $1 == k && ($2 == "=" || $3 == "=") {
      sub(/^[^=]+=[[:space:]]*/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print
      exit
    }
  ' "${file}"
}

conf_set_option() {
  local file="$1" key="$2" value="$3"
  local tmp
  mkdir -p "$(dirname "${file}")"
  touch "${file}"
  tmp="$(mktemp)"
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    sed -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "${file}" > "${tmp}"
  else
    cp "${file}" "${tmp}"
    printf '\n%s = %s\n' "${key}" "${value}" >> "${tmp}"
  fi
  mv "${tmp}" "${file}"
  chmod 640 "${file}" 2>/dev/null || true
}

ensure_tenant_odoo_conf() {
  local conf_path dir
  conf_path="$(tenant_odoo_conf_path)"
  dir="$(dirname "${conf_path}")"
  mkdir -p "${dir}"
  chmod 755 "${SOVIEZ_VOLUME_ROOT}" "${SOVIEZ_VOLUME_ROOT}/${WEB_CONTAINER}" "${dir}" 2>/dev/null || true

  if [[ ! -f "${conf_path}" ]]; then
    cat > "${conf_path}" <<EOF
[options]
; Per-tenant runtime — managed by soviez.sh (--new auto-config / --formworkers)
workers = 0
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
addons_path = /opt/soviez-erp/addons,/opt/soviez-erp/odoo/addons
data_dir = /root/.local/share/Odoo
list_db = False
EOF
    chmod 640 "${conf_path}"
    log_file "Created tenant runtime odoo.conf at ${conf_path}"
  fi
}

# Enumerate tenant env sheets (deduplicated by realpath).
collect_tenant_env_paths() {
  local -a paths=() seen=() real path
  shopt -s nullglob
  for path in \
      "${INSTANCE_ROOT}"/.soviez_*.env \
      "${INSTANCE_ROOT}"/.soviez.env \
      "$(pwd)"/.soviez_*.env \
      "$(pwd)"/.soviez.env; do
    [[ -f "${path}" ]] || continue
    real="$(readlink -f "${path}" 2>/dev/null || echo "${path}")"
    local dup=0 prev
    for prev in "${seen[@]:-}"; do
      [[ "${prev}" == "${real}" ]] && dup=1 && break
    done
    (( dup == 1 )) && continue
    seen+=("${real}")
    paths+=("${path}")
  done
  shopt -u nullglob
  printf '%s\n' "${paths[@]}"
}

# Sum reserved RAM (MB) and CPU cores from env sheets + odoo.conf files.
# Optional $1 = WEB_CONTAINER name to exclude (when allocating for that tenant).
scan_reserved_resources() {
  local exclude_web="${1:-}"
  local path web db workers soft hard ram_mb cpu_cores pg_mb
  local total_ram_mb=0 total_cpu=0

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    web="$(grep -E '^SOVIEZ_WEB_CONTAINER=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    [[ -n "${web}" ]] || continue
    [[ -n "${exclude_web}" && "${web}" == "${exclude_web}" ]] && continue

    ram_mb="$(grep -E '^SOVIEZ_ALLOC_RAM_MB=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    cpu_cores="$(grep -E '^SOVIEZ_ALLOC_CORES=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    pg_mb="$(grep -E '^SOVIEZ_PG_SHARED_BUFFERS_MB=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"

    if [[ -z "${ram_mb}" || ! "${ram_mb}" =~ ^[0-9]+$ ]]; then
      workers="$(conf_get_option "${SOVIEZ_VOLUME_ROOT}/${web}/conf/odoo.conf" workers || true)"
      hard="$(conf_get_option "${SOVIEZ_VOLUME_ROOT}/${web}/conf/odoo.conf" limit_memory_hard || true)"
      if [[ -n "${workers}" && "${workers}" =~ ^[0-9]+$ && "${workers}" -gt 0 ]]; then
        ram_mb=$(( workers * 800 ))
      elif [[ -n "${hard}" && "${hard}" =~ ^[0-9]+$ ]]; then
        ram_mb=$(( hard / 1024 / 1024 ))
      else
        ram_mb=4096
      fi
      [[ -n "${pg_mb}" && "${pg_mb}" =~ ^[0-9]+$ ]] && ram_mb=$(( ram_mb + pg_mb ))
    fi

    if [[ -z "${cpu_cores}" || ! "${cpu_cores}" =~ ^[0-9]+$ ]]; then
      cpu_cores="$(grep -E '^SOVIEZ_DOCKER_CPUS=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
      if [[ -z "${cpu_cores}" || ! "${cpu_cores}" =~ ^[0-9]+$ ]]; then
        workers="$(conf_get_option "${SOVIEZ_VOLUME_ROOT}/${web}/conf/odoo.conf" workers || true)"
        if [[ -n "${workers}" && "${workers}" =~ ^[0-9]+$ && "${workers}" -gt 0 ]]; then
          cpu_cores=$(( (workers - 1) / 2 ))
          (( cpu_cores < 1 )) && cpu_cores=1
        else
          cpu_cores=1
        fi
      fi
    fi

    total_ram_mb=$(( total_ram_mb + ram_mb ))
    total_cpu=$(( total_cpu + cpu_cores ))
  done < <(collect_tenant_env_paths)

  printf '%s %s\n' "${total_ram_mb}" "${total_cpu}"
}

host_resource_utilization_percent() {
  local total_ram total_cpu reserved reserved_ram reserved_cpu ram_pct cpu_pct
  total_ram="$(host_total_ram_mb)"
  total_cpu="$(host_total_cpu_cores)"
  read -r reserved_ram reserved_cpu < <(scan_reserved_resources "")
  (( total_ram < 1 )) && total_ram=4096
  (( total_cpu < 1 )) && total_cpu=2
  ram_pct=$(( reserved_ram * 100 / total_ram ))
  cpu_pct=$(( reserved_cpu * 100 / total_cpu ))
  if (( ram_pct > cpu_pct )); then
    echo "${ram_pct}"
  else
    echo "${cpu_pct}"
  fi
}

prompt_yes_no() {
  local question="$1" answer
  while true; do
    read -r -p "${question} (y/n): " answer
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

print_resource_pressure_warning() {
  local utilization="$1"
  echo ""
  echo -e "${C_RED}${C_BOLD}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_RED}${C_BOLD}║  WARNING — HOST RESOURCES ${utilization}% UTILIZED (THRESHOLD ${RESOURCE_UTIL_WARN_PCT}%)${C_RESET}"
  echo -e "${C_RED}${C_BOLD}╠══════════════════════════════════════════════════════════════════════╣${C_RESET}"
  echo -e "${C_RED}${C_BOLD}║${C_RESET}  Existing tenants already reserve most CPU/RAM on this node."
  echo -e "${C_RED}${C_BOLD}║${C_RESET}  Provision a larger server or add a new node before stacking tenants."
  echo -e "${C_RED}${C_BOLD}║${C_RESET}  Sizing guide: ${RESOURCE_SYSTEM_REQUIREMENTS_URL}"
  echo -e "${C_RED}${C_BOLD}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
  echo ""
}

# Compute allocation for the active WEB_CONTAINER topology (excludes self when re-tuning).
compute_allocation_for_tenant() {
  local exclude_web="${1:-${WEB_CONTAINER}}"
  local total_ram total_cpu reserved_ram reserved_cpu
  local usable_ram usable_cpu tenant_slots

  total_ram="$(host_total_ram_mb)"
  total_cpu="$(host_total_cpu_cores)"
  read -r reserved_ram reserved_cpu < <(scan_reserved_resources "${exclude_web}")

  # Reserve ~15% for kernel, Docker daemon, Nginx, and headroom.
  usable_ram=$(( total_ram * 85 / 100 - reserved_ram ))
  usable_cpu=$(( total_cpu - reserved_cpu ))

  (( usable_ram < 2048 )) && usable_ram=2048
  (( usable_cpu < 1 )) && usable_cpu=1

  tenant_slots="$(collect_tenant_env_paths | wc -l | tr -d ' ')"
  if [[ -n "${exclude_web}" ]] && container_exists "${exclude_web}"; then
    : # re-tuning existing tenant — grant full remaining slice
  else
    tenant_slots=$(( tenant_slots + 1 ))
  fi
  (( tenant_slots < 1 )) && tenant_slots=1

  ALLOC_RAM_MB=$(( usable_ram / tenant_slots ))
  ALLOC_CORES=$(( usable_cpu / tenant_slots ))
  (( ALLOC_RAM_MB < 2048 )) && ALLOC_RAM_MB=2048
  (( ALLOC_CORES < 1 )) && ALLOC_CORES=1
  (( ALLOC_CORES > usable_cpu )) && ALLOC_CORES="${usable_cpu}"

  WORKERS=$(( ALLOC_CORES * 2 + 1 ))
  LIMIT_SOFT_BYTES=$(( WORKERS * 600 * 1024 * 1024 ))
  LIMIT_HARD_BYTES=$(( WORKERS * 800 * 1024 * 1024 ))
  PG_SHARED_MB=$(( ALLOC_RAM_MB * 25 / 100 ))
  PG_EFFECTIVE_MB=$(( ALLOC_RAM_MB * 75 / 100 ))
  (( PG_SHARED_MB < 128 )) && PG_SHARED_MB=128
  DOCKER_MEM_MB=$(( LIMIT_HARD_BYTES / 1024 / 1024 + PG_SHARED_MB + 512 ))
  DOCKER_CPUS="${ALLOC_CORES}"

  log_file "ALLOC tenant=${WEB_CONTAINER} ram_mb=${ALLOC_RAM_MB} cores=${ALLOC_CORES} workers=${WORKERS} pg_shared=${PG_SHARED_MB}MB docker_mem=${DOCKER_MEM_MB}MB"
}

persist_resource_tuning_env() {
  persist_env_key "SOVIEZ_WORKERS" "${WORKERS}"
  persist_env_key "SOVIEZ_LIMIT_MEMORY_SOFT" "${LIMIT_SOFT_BYTES}"
  persist_env_key "SOVIEZ_LIMIT_MEMORY_HARD" "${LIMIT_HARD_BYTES}"
  persist_env_key "SOVIEZ_PG_SHARED_BUFFERS_MB" "${PG_SHARED_MB}"
  persist_env_key "SOVIEZ_PG_EFFECTIVE_CACHE_MB" "${PG_EFFECTIVE_MB}"
  persist_env_key "SOVIEZ_DOCKER_MEM_MB" "${DOCKER_MEM_MB}"
  persist_env_key "SOVIEZ_DOCKER_CPUS" "${DOCKER_CPUS}"
  persist_env_key "SOVIEZ_ALLOC_RAM_MB" "${ALLOC_RAM_MB}"
  persist_env_key "SOVIEZ_ALLOC_CORES" "${ALLOC_CORES}"
  load_env_file
}

postgres_tuning_run_args() {
  local -a args=()
  if [[ -n "${SOVIEZ_PG_SHARED_BUFFERS_MB:-${PG_SHARED_MB}}" ]]; then
    args+=(postgres -c "shared_buffers=${SOVIEZ_PG_SHARED_BUFFERS_MB:-${PG_SHARED_MB}}MB")
    args+=(-c "effective_cache_size=${SOVIEZ_PG_EFFECTIVE_CACHE_MB:-${PG_EFFECTIVE_MB}}MB")
    args+=(-c "maintenance_work_mem=64MB")
    args+=(-c "work_mem=16MB")
  fi
  printf '%s\0' "${args[@]}"
}

recreate_postgres_with_tuning() {
  local -a pg_cmd=()
  local blob
  blob="$(postgres_tuning_run_args)"
  if [[ -n "${blob}" ]]; then
    IFS=$'\0' read -r -a pg_cmd <<< "${blob}"
  fi

  ui_wait "Recreating ${DB_CONTAINER} on volume ${DB_VOLUME} with tuned PostgreSQL buffers..."
  docker run -d \
    --name "${DB_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    -e POSTGRES_DB=postgres \
    -e POSTGRES_USER=soviez \
    -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -v "${DB_VOLUME}:/var/lib/postgresql/data" \
    "${DB_IMAGE}" \
    "${pg_cmd[@]}" >>"${LOG_FILE}" 2>&1

  wait_for_postgres
  ui_ok "PostgreSQL ${DB_CONTAINER} online with tuned buffers"
}

apply_tenant_resource_tuning() {
  ensure_tenant_odoo_conf
  local conf_path
  conf_path="$(tenant_odoo_conf_path)"

  persist_resource_tuning_env

  if ! container_exists "${WEB_CONTAINER}"; then
    ui_error "Web container ${WEB_CONTAINER} does not exist — provision the tenant first."
    return 1
  fi

  ui_info "Applying tuning to ${WEB_CONTAINER}: workers=${WORKERS}, cores=${DOCKER_CPUS}, ram=${DOCKER_MEM_MB}MB"

  ui_wait "Stopping ${WEB_CONTAINER} (flush in-flight transactions)..."
  docker stop "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true

  if container_exists "${DB_CONTAINER}"; then
    ui_wait "Stopping ${DB_CONTAINER}..."
    docker stop "${DB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
    docker rm "${DB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
  fi

  recreate_postgres_with_tuning

  conf_set_option "${conf_path}" workers "${WORKERS}"
  conf_set_option "${conf_path}" limit_memory_soft "${LIMIT_SOFT_BYTES}"
  conf_set_option "${conf_path}" limit_memory_hard "${LIMIT_HARD_BYTES}"

  ui_wait "Applying Docker cgroup limits on ${WEB_CONTAINER}..."
  docker update \
    --cpus="${DOCKER_CPUS}" \
    --memory="${DOCKER_MEM_MB}m" \
    --memory-swap="${DOCKER_MEM_MB}m" \
    "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1

  ui_wait "Starting ${WEB_CONTAINER} with updated odoo.conf..."
  docker start "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1

  ui_ok "Resource tuning complete for ${WEB_CONTAINER}"
  echo -e "  ${C_DIM}Config:${C_RESET} ${conf_path}"
  echo -e "  ${C_DIM}Workers:${C_RESET} ${WORKERS}  ${C_DIM}Soft/Hard:${C_RESET} $(( LIMIT_SOFT_BYTES / 1024 / 1024 ))MB / $(( LIMIT_HARD_BYTES / 1024 / 1024 ))MB"
  echo -e "  ${C_DIM}PostgreSQL:${C_RESET} shared_buffers=${PG_SHARED_MB}MB  effective_cache_size=${PG_EFFECTIVE_MB}MB"
}

prompt_resource_tuning_on_new() {
  local utilization
  utilization="$(host_resource_utilization_percent)"
  ui_info "Host resource scan: ~${utilization}% utilized (RAM/CPU reservation model)"

  if (( utilization > RESOURCE_UTIL_WARN_PCT )); then
    print_resource_pressure_warning "${utilization}"
    if prompt_yes_no "Continue creating this tenant WITHOUT auto-configuration"; then
      AUTO_TUNE_ON_NEW=0
    else
      ui_error "Tenant provisioning aborted — upgrade hardware or add a node, then retry."
      exit 1
    fi
    return 0
  fi

  if prompt_yes_no "Auto-configure Odoo workers and PostgreSQL buffers for optimal performance"; then
    AUTO_TUNE_ON_NEW=1
    ui_info "Auto-tuning will run after containers launch (adjust later with --formworkers)."
  else
    AUTO_TUNE_ON_NEW=0
    ui_info "Skipped auto-tuning — run sudo ./soviez.sh --formworkers ${WEB_CONTAINER} later."
  fi
}

ensure_postgres_container() {
  if container_running "${DB_CONTAINER}"; then
    log_file "DB ${DB_CONTAINER} already running"
  elif container_exists "${DB_CONTAINER}"; then
    docker start "${DB_CONTAINER}" >/dev/null
  else
    local -a pg_cmd=() blob
    blob="$(postgres_tuning_run_args)"
    if [[ -n "${blob}" ]]; then
      IFS=$'\0' read -r -a pg_cmd <<< "${blob}"
    fi
    if ((${#pg_cmd[@]} > 0)); then
      docker run -d \
        --name "${DB_CONTAINER}" \
        --restart unless-stopped \
        --network "${NETWORK_NAME}" \
        -e POSTGRES_DB=postgres \
        -e POSTGRES_USER=soviez \
        -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
        -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
        -v "${DB_VOLUME}:/var/lib/postgresql/data" \
        "${DB_IMAGE}" \
        "${pg_cmd[@]}" >/dev/null
    else
      docker run -d \
        --name "${DB_CONTAINER}" \
        --restart unless-stopped \
        --network "${NETWORK_NAME}" \
        -e POSTGRES_DB=postgres \
        -e POSTGRES_USER=soviez \
        -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
        -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
        -v "${DB_VOLUME}:/var/lib/postgresql/data" \
        "${DB_IMAGE}" >/dev/null
    fi
  fi
  wait_for_postgres
}

resume_postgres_container() {
  if container_running "${DB_CONTAINER}"; then
    ui_ok "PostgreSQL already running (${DB_CONTAINER})"
    wait_for_postgres
    return 0
  fi
  if container_exists "${DB_CONTAINER}"; then
    ui_wait "Starting stopped PostgreSQL (${DB_CONTAINER})..."
    docker start "${DB_CONTAINER}" >>"${LOG_FILE}" 2>&1
    wait_for_postgres
    ui_ok "PostgreSQL started (${DB_CONTAINER})"
    return 0
  fi
  ui_wait "Creating PostgreSQL (${DB_CONTAINER})..."
  ensure_postgres_container
  ui_ok "PostgreSQL created (${DB_CONTAINER})"
}

resume_web_container() {
  if container_running "${WEB_CONTAINER}"; then
    # Recreate when the custom-addons bind is absent (legacy /etc layout or pre-mount image).
    if web_needs_addons_remount; then
      ui_wait "Recycling ${WEB_CONTAINER} to attach custom addons mount..."
      docker rm -f "${WEB_CONTAINER}" >/dev/null 2>&1 || true
      launch_web_container
      ui_ok "Web ERP recreated with addons mount (${WEB_CONTAINER})"
      return 0
    fi
    ui_ok "Web ERP already running (${WEB_CONTAINER})"
    return 0
  fi
  if container_exists "${WEB_CONTAINER}"; then
    if web_needs_addons_remount; then
      ui_wait "Recycling stopped ${WEB_CONTAINER} to attach custom addons mount..."
      docker rm -f "${WEB_CONTAINER}" >/dev/null 2>&1 || true
      launch_web_container
      ui_ok "Web ERP recreated with addons mount (${WEB_CONTAINER})"
      return 0
    fi
    ui_wait "Starting stopped web ERP (${WEB_CONTAINER})..."
    docker start "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1
    ui_ok "Web ERP started (${WEB_CONTAINER})"
    return 0
  fi
  ui_wait "Creating web ERP (${WEB_CONTAINER})..."
  launch_web_container
  ui_ok "Web ERP created (${WEB_CONTAINER})"
}

# True when the live container is missing the expected custom-addons bind mount.
web_needs_addons_remount() {
  [[ -n "${CUSTOM_ADDONS_HOST_PATH}" ]] || return 1
  container_exists "${WEB_CONTAINER}" || return 1
  local mounts
  mounts="$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "${WEB_CONTAINER}" 2>/dev/null || true)"
  [[ "${mounts}" != *"${CUSTOM_ADDONS_CONTAINER_PATH}"* ]]
}

ensure_custom_addons_dir() {
  resolve_custom_addons_host_path

  if [[ -z "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    return 0
  fi

  # Central root-level layout: /soviez/soviez_web[_N]/addons
  mkdir -p "${SOVIEZ_HOST_ROOT}"
  mkdir -p "$(dirname "${CUSTOM_ADDONS_HOST_PATH}")"
  mkdir -p "${CUSTOM_ADDONS_HOST_PATH}"

  chmod 755 "${SOVIEZ_HOST_ROOT}" \
    "$(dirname "${CUSTOM_ADDONS_HOST_PATH}")" \
    "${CUSTOM_ADDONS_HOST_PATH}"

  # Allow the invoking operator (via sudo) to drop modules without staying root.
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown "${SUDO_USER}:${SUDO_USER}" \
      "$(dirname "${CUSTOM_ADDONS_HOST_PATH}")" \
      "${CUSTOM_ADDONS_HOST_PATH}" 2>/dev/null || true
  fi

  # Friendly README on first create
  if [[ ! -f "${CUSTOM_ADDONS_HOST_PATH}/README.txt" ]]; then
    cat > "${CUSTOM_ADDONS_HOST_PATH}/README.txt" <<EOF
Soviez ERP — custom addons drop folder for ${WEB_CONTAINER}

Place Odoo/Soviez modules here (each module in its own subdirectory).
They are bind-mounted into the container at:
  ${CUSTOM_ADDONS_CONTAINER_PATH}

Runtime --addons-path includes that directory last:
  /opt/soviez-erp/addons,/opt/soviez-erp/odoo/addons,${CUSTOM_ADDONS_CONTAINER_PATH}

After dropping a module, update the database Apps list from the UI
or run: sudo ./soviez.sh --update
EOF
  fi
}

launch_web_container() {
  local addons_cli runtime_conf
  local -a volume_args=() docker_limits=()

  ensure_host_ledger_dir
  ensure_custom_addons_dir
  ensure_tenant_odoo_conf
  runtime_conf="$(tenant_odoo_conf_path)"

  volume_args+=(
    -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore"
    -v "${HOST_SOVIEZ_DIR}:/root/.soviez"
    -v "${runtime_conf}:/opt/soviez-erp/tenant.odoo.conf:ro"
  )

  addons_cli="/opt/soviez-erp/addons,/opt/soviez-erp/odoo/addons"
  if [[ -n "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    volume_args+=(
      -v "${CUSTOM_ADDONS_HOST_PATH}:${CUSTOM_ADDONS_CONTAINER_PATH}"
    )
    addons_cli="${addons_cli},${CUSTOM_ADDONS_CONTAINER_PATH}"
  fi

  if [[ -n "${SOVIEZ_DOCKER_CPUS:-}" ]]; then
    docker_limits+=(--cpus="${SOVIEZ_DOCKER_CPUS}")
  fi
  if [[ -n "${SOVIEZ_DOCKER_MEM_MB:-}" ]]; then
    docker_limits+=(--memory="${SOVIEZ_DOCKER_MEM_MB}m" --memory-swap="${SOVIEZ_DOCKER_MEM_MB}m")
  fi

  docker run -d \
    --name "${WEB_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    --mac-address "${SOVIEZ_CONTAINER_MAC}" \
    -p "${SOVIEZ_HOST_PORT}:8069" \
    -e POSTGRES_USER=soviez \
    -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    "${docker_limits[@]}" \
    "${volume_args[@]}" \
    "${APP_IMAGE}" \
    python3 soviez-bin -c /opt/soviez-erp/tenant.odoo.conf \
      --addons-path="${addons_cli}" \
      --db_host="${DB_CONTAINER}" \
      --db_port=5432 \
      --db_user=soviez \
      --db_password="${SOVIEZ_DB_PASSWORD}" \
      --data-dir=/root/.local/share/Odoo \
      --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" >/dev/null
}

# ===========================================================================
list_odoo_databases() {
  if [[ -n "${SOVIEZ_DB_NAME:-}" ]]; then
    printf '%s\n' "${SOVIEZ_DB_NAME}"
    return 0
  fi
  docker exec "${DB_CONTAINER}" \
    psql -U soviez -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" \
    2>/dev/null | sed '/^$/d' || true
}

purge_frontend_assets() {
  local dbname="$1"
  docker exec "${DB_CONTAINER}" \
    psql -U soviez -d "${dbname}" -v ON_ERROR_STOP=1 -c \
    "DELETE FROM ir_attachment
     WHERE url LIKE '/web/assets/%'
        OR url LIKE '/web/content/%assets%'
        OR name ILIKE 'web.assets_%'
        OR name ILIKE 'web_enterprise.assets_%'
        OR name ILIKE '%.assets_%.min.js'
        OR name ILIKE '%.assets_%.min.css';" >/dev/null
}

run_schema_upgrades() {
  local dbname
  local dbs
  local count=0
  local upgrade_rc=0
  local addons_cli="/opt/soviez-erp/addons,/opt/soviez-erp/odoo/addons"
  local -a volume_args=(
    -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore"
    -v "${HOST_SOVIEZ_DIR}:/root/.soviez"
  )

  ensure_host_ledger_dir
  if [[ -n "${CUSTOM_ADDONS_HOST_PATH}" && -d "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    volume_args+=(-v "${CUSTOM_ADDONS_HOST_PATH}:${CUSTOM_ADDONS_CONTAINER_PATH}")
    addons_cli="${addons_cli},${CUSTOM_ADDONS_CONTAINER_PATH}"
  fi

  mapfile -t dbs < <(list_odoo_databases)
  if ((${#dbs[@]} == 0)); then
    ui_warn "No application databases found — skipping schema upgrade."
    return 0
  fi

  for dbname in "${dbs[@]}"; do
    [[ -z "${dbname}" ]] && continue
    if [[ ! "${dbname}" =~ ^[A-Za-z0-9_:-]+$ ]]; then
      ui_error "Refusing unsafe database name: ${dbname}"
      return 1
    fi
    count=$((count + 1))
    set +e
    docker run --rm \
      --network "${NETWORK_NAME}" \
      --mac-address "${SOVIEZ_CONTAINER_MAC}" \
      -e POSTGRES_USER=soviez \
      -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      "${volume_args[@]}" \
      "${APP_IMAGE}" \
      python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
        --addons-path="${addons_cli}" \
        --db_host="${DB_CONTAINER}" \
        --db_port=5432 \
        --db_user=soviez \
        --db_password="${SOVIEZ_DB_PASSWORD}" \
        --data-dir=/root/.local/share/Odoo \
        --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" \
        -d "${dbname}" \
        -u "${UPGRADE_MODULES}" \
        --stop-after-init >>"${LOG_FILE}" 2>&1
    upgrade_rc=$?
    set -e
    if (( upgrade_rc != 0 )); then
      ui_error "Schema upgrade failed for '${dbname}' (exit ${upgrade_rc})."
      return "${upgrade_rc}"
    fi
    purge_frontend_assets "${dbname}" || return 1
  done
  log_file "Upgraded ${count} database(s)"
}

require_complete_env() {
  if [[ -z "${SOVIEZ_CONTAINER_MAC:-}" || -z "${SOVIEZ_DB_PASSWORD:-}" || -z "${SOVIEZ_HOST_PORT:-}" || -z "${SOVIEZ_ADMIN_PASSWORD:-}" ]]; then
    ui_error "${ENV_FILE} is missing required secrets (MAC / DB password / admin password / host port)."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Public IP / DNS / Nginx / Certbot / UFW  (--init / --new)
# ---------------------------------------------------------------------------
detect_public_ip() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(python3 - <<'PY' 2>/dev/null || true
import urllib.request
print(urllib.request.urlopen("https://api.ipify.org", timeout=8).read().decode().strip())
PY
)"
  fi
  if [[ -z "${ip}" ]] || ! [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    ui_error "Could not detect public IPv4 (api.ipify.org unreachable)."
    exit 1
  fi
  printf '%s\n' "${ip}"
}

# Resolve PUBLIC_IP for Nginx force-hijack binds (env → cache → detect).
ensure_public_bind_ip() {
  if [[ -n "${PUBLIC_IP:-}" && "${PUBLIC_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "${PUBLIC_IP}"
    return 0
  fi
  if [[ -n "${SOVIEZ_PUBLIC_IP:-}" && "${SOVIEZ_PUBLIC_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    PUBLIC_IP="${SOVIEZ_PUBLIC_IP}"
    printf '%s\n' "${PUBLIC_IP}"
    return 0
  fi
  PUBLIC_IP="$(detect_public_ip)"
  printf '%s\n' "${PUBLIC_IP}"
}

resolve_domain_ips() {
  local domain="$1"
  python3 - "${domain}" <<'PY'
import socket
import sys
domain = sys.argv[1]
try:
    infos = socket.getaddrinfo(domain, None)
except Exception:
    sys.exit(2)
ips = sorted({i[4][0] for i in infos if i[4] and i[4][0]})
print("\n".join(ips))
PY
}

normalize_domain() {
  local d="$1"
  d="${d,,}"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d%%:*}"
  printf '%s\n' "${d}"
}

prompt_domain_confirmed() {
  local d1 d2
  while true; do
    echo ""
    read -r -p "🌐  Enter your domain or subdomain: " d1
    d1="$(normalize_domain "${d1}")"
    if [[ -z "${d1}" || ! "${d1}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
      ui_warn "Invalid domain. Example: erp.example.com"
      continue
    fi
    read -r -p "🔁  Confirm domain (type again): " d2
    d2="$(normalize_domain "${d2}")"
    if [[ "${d1}" != "${d2}" ]]; then
      ui_warn "Domains did not match. Try again."
      continue
    fi
    TENANT_DOMAIN="${d1}"
    return 0
  done
}

dns_validation_loop() {
  local public_ip="$1"
  local domain="$2"
  local resolved
  local answer

  while true; do
    ui_wait "Checking DNS for ${domain} → ${public_ip}..."
    set +e
    resolved="$(resolve_domain_ips "${domain}" 2>/dev/null)"
    local rc=$?
    set -e

    if (( rc == 0 )) && printf '%s\n' "${resolved}" | grep -Fxq "${public_ip}"; then
      ui_ok "DNS matched — ${domain} resolves to ${public_ip}"
      return 0
    fi

    echo ""
    ui_warn "Domain is not pointed to this IP yet. DNS propagation can take up to 48 hours."
    if [[ -n "${resolved}" ]]; then
      echo -e "  ${C_DIM}Currently resolves to:${C_RESET} ${resolved//$'\n'/, }"
    else
      echo -e "  ${C_DIM}Currently resolves to:${C_RESET} (none / NXDOMAIN)"
    fi
    echo -e "  ${C_DIM}Expected Public IP:${C_RESET} ${public_ip}"
    echo ""
    read -r -p "Retry DNS check now? (y/n) — or type 'force' to override: " answer
    answer="${answer,,}"
    case "${answer}" in
      y|yes) continue ;;
      force)
        ui_warn "Operator force-override accepted — continuing without verified DNS."
        return 0
        ;;
      *)
        ui_error "DNS not verified. Exiting. Re-run ./soviez.sh --new when ready."
        exit 1
        ;;
    esac
  done
}

# Ensure http-context map + ERP proxy limits exist. Prevents:
#   nginx: [emerg] unknown "connection_upgrade" variable
# Safe to call even when --init was skipped or interrupted.
ensure_nginx_global_limits() {
  local needs_write=0

  mkdir -p /etc/nginx/conf.d

  if [[ ! -f "${NGINX_LIMITS_CONF}" ]]; then
    needs_write=1
    log_file "Nginx limits file missing — will write ${NGINX_LIMITS_CONF}"
  elif ! grep -Eq 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade' "${NGINX_LIMITS_CONF}"; then
    needs_write=1
    log_file "Nginx limits file lacks connection_upgrade map — rewriting ${NGINX_LIMITS_CONF}"
  fi

  if (( needs_write == 1 )); then
    ui_wait "Writing Nginx global limits (connection_upgrade map)..."
    cat > "${NGINX_LIMITS_CONF}" <<'EOF'
# Soviez ERP — global proxy limits for heavy ERP/Odoo traffic
client_max_body_size 512M;
proxy_read_timeout 720s;
proxy_connect_timeout 720s;
proxy_send_timeout 720s;

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    ui_ok "Nginx global limits written (${NGINX_LIMITS_CONF})"
  else
    log_file "Nginx global limits already present with connection_upgrade map"
  fi
}

# Back-compat alias used by --init progress helper.
configure_nginx_global_limits() {
  ensure_nginx_global_limits
  if ! nginx -t >>"${LOG_FILE}" 2>&1; then
    ui_error "Nginx configuration test failed after writing ${NGINX_LIMITS_CONF}"
    return 1
  fi
  systemctl reload nginx >>"${LOG_FILE}" 2>&1 || systemctl start nginx >>"${LOG_FILE}" 2>&1 || true
}

ssl_selfsigned_crt_path() {
  printf '%s\n' "/etc/ssl/certs/soviez-${1}.crt"
}

ssl_selfsigned_key_path() {
  printf '%s\n' "/etc/ssl/private/soviez-${1}.key"
}

ssl_le_fullchain_path() {
  printf '%s\n' "/etc/letsencrypt/live/${1}/fullchain.pem"
}

ssl_le_privkey_path() {
  printf '%s\n' "/etc/letsencrypt/live/${1}/privkey.pem"
}

# Guarantee Certbot's nginx authenticator/installer plugin is present and loadable.
ensure_certbot_nginx_plugin() {
  export DEBIAN_FRONTEND=noninteractive
  ui_wait "Ensuring Certbot nginx plugin (python3-certbot-nginx)..."
  if ! command -v certbot >/dev/null 2>&1; then
    apt-get install -y certbot python3-certbot-nginx >>"${LOG_FILE}" 2>&1 || {
      ui_error "Failed to install certbot / python3-certbot-nginx — see ${LOG_FILE}"
      return 1
    }
  else
    apt-get install -y certbot python3-certbot-nginx >>"${LOG_FILE}" 2>&1 || true
  fi

  set +e
  local plugins
  plugins="$(certbot plugins 2>/dev/null)"
  local plug_rc=$?
  set -e
  log_file "certbot plugins (rc=${plug_rc}): ${plugins}"

  if ! printf '%s' "${plugins}" | grep -Eiq '(^|[[:space:]])nginx([[:space:]]|$)|\* nginx'; then
    ui_warn "Certbot nginx plugin not loaded — force-reinstalling python3-certbot-nginx..."
    apt-get install -y --reinstall python3-certbot-nginx certbot >>"${LOG_FILE}" 2>&1 || {
      ui_error "Force-reinstall of python3-certbot-nginx failed — see ${LOG_FILE}"
      return 1
    }
    set +e
    plugins="$(certbot plugins 2>/dev/null)"
    set -e
    log_file "certbot plugins after reinstall: ${plugins}"
    if ! printf '%s' "${plugins}" | grep -Eiq '(^|[[:space:]])nginx([[:space:]]|$)|\* nginx'; then
      ui_error "The requested nginx plugin does not appear to be installed (python3-certbot-nginx inactive)."
      return 1
    fi
  fi
  ui_ok "Certbot nginx plugin verified"
}

# Generate 2048-bit self-signed cert for Cloudflare Full / Virtualmin 443 competition.
# force=1 regenerates even if files exist.
ensure_selfsigned_cert() {
  local domain="$1"
  local force="${2:-0}"
  local crt key
  crt="$(ssl_selfsigned_crt_path "${domain}")"
  key="$(ssl_selfsigned_key_path "${domain}")"

  require_cmd openssl
  mkdir -p /etc/ssl/certs /etc/ssl/private
  chmod 755 /etc/ssl/certs
  chmod 700 /etc/ssl/private

  if [[ "${force}" != "1" && -f "${crt}" && -f "${key}" ]]; then
    log_file "Self-signed cert already present for ${domain}"
    return 0
  fi

  if [[ "${force}" == "1" ]]; then
    ui_wait "Refreshing self-signed certificate for ${domain}..."
  else
    ui_wait "Generating high-security self-signed certificate for ${domain}..."
  fi

  # Prefer SAN-capable OpenSSL 1.1.1+; fall back to CN-only on older builds.
  set +e
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "${key}" -out "${crt}" \
    -subj "/CN=${domain}/O=Soviez ERP Fallback/C=US" \
    -addext "subjectAltName=DNS:${domain}" >>"${LOG_FILE}" 2>&1
  local rc=$?
  if (( rc != 0 )); then
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "${key}" -out "${crt}" \
      -subj "/CN=${domain}/O=Soviez ERP Fallback/C=US" >>"${LOG_FILE}" 2>&1
    rc=$?
  fi
  set -e

  if (( rc != 0 )) || [[ ! -f "${crt}" || ! -f "${key}" ]]; then
    ui_error "Failed to generate self-signed certificate for ${domain} — see ${LOG_FILE}"
    return 1
  fi
  chmod 644 "${crt}"
  chmod 640 "${key}"
  ui_ok "Self-signed certificate ready (${crt})"
}

cert_issuer_summary() {
  local crt="$1"
  if [[ ! -f "${crt}" ]]; then
    printf '%s\n' "(missing)"
    return 0
  fi
  openssl x509 -in "${crt}" -noout -issuer 2>/dev/null | sed 's/^issuer=//' || printf '%s\n' "(unreadable)"
}

cert_is_letsencrypt_file() {
  local crt="$1"
  [[ -f "${crt}" ]] || return 1
  local issuer
  issuer="$(cert_issuer_summary "${crt}")"
  printf '%s' "${issuer}" | grep -Eiq "Let's Encrypt|ISRG Root|R[0-9]+"
}

nginx_site_path() {
  printf '%s\n' "/etc/nginx/sites-available/soviez-${1}.conf"
}

remove_nginx_site_for_domain() {
  local domain="$1"
  local site enabled
  site="$(nginx_site_path "${domain}")"
  enabled="/etc/nginx/sites-enabled/soviez-${domain}.conf"
  rm -f "${site}" "${enabled}" 2>/dev/null || true
  log_file "Removed Nginx site files for ${domain}"
}

nginx_site_has_443() {
  local site
  site="$(nginx_site_path "$1")"
  [[ -f "${site}" ]] || return 1
  grep -Eq 'listen[[:space:]]+[^;]*443' "${site}" 2>/dev/null
}

# Unique routing fingerprint — never collide with another Odoo on the same host.
tenant_identity_token() {
  local idx="${INSTANCE_INDEX:-${SOVIEZ_INSTANCE_INDEX:-}}"
  if [[ -z "${idx}" ]]; then
    idx="0"
  fi
  printf 'soviez_%s\n' "${idx}"
}

# Write complete dual-stack vhost: :80 ACME + HTTPS redirect, :443 SSL proxy to ERP.
# ssl_kind: selfsigned | letsencrypt
# Force-hijack: bind listen ${PUBLIC_IP}:80/443 so Virtualmin IP:443 cannot steal traffic.
write_nginx_site() {
  local domain="$1"
  local host_port="$2"
  local ssl_kind="${3:-selfsigned}"
  local site_file enabled_link crt_file key_file bind_ip tenant_token

  site_file="$(nginx_site_path "${domain}")"
  enabled_link="/etc/nginx/sites-enabled/soviez-${domain}.conf"
  bind_ip="$(ensure_public_bind_ip)"
  tenant_token="$(tenant_identity_token)"

  ensure_nginx_global_limits

  if [[ "${ssl_kind}" == "letsencrypt" ]]; then
    crt_file="$(ssl_le_fullchain_path "${domain}")"
    key_file="$(ssl_le_privkey_path "${domain}")"
    if [[ ! -f "${crt_file}" || ! -f "${key_file}" ]]; then
      ui_warn "Let's Encrypt files missing for ${domain} — falling back to self-signed paths"
      ssl_kind="selfsigned"
    fi
  fi

  if [[ "${ssl_kind}" == "selfsigned" ]]; then
    ensure_selfsigned_cert "${domain}" 0 || return 1
    crt_file="$(ssl_selfsigned_crt_path "${domain}")"
    key_file="$(ssl_selfsigned_key_path "${domain}")"
  fi

  cat > "${site_file}" <<EOF
# Soviez ERP tenant — ${domain} → 127.0.0.1:${host_port}
# SSL mode: ${ssl_kind}
# Force-hijack bind: ${bind_ip}:80 / ${bind_ip}:443 (matches Virtualmin explicit-IP priority)
# Tenant header: X-Soviez-Tenant: ${tenant_token}

server {
    listen ${bind_ip}:80;
    server_name ${domain};

    # Tenant-specific footprint — proves THIS vhost answered (not another Odoo on the IP).
    add_header X-Soviez-Tenant "${tenant_token}" always;

    client_max_body_size 512M;

    # Preserve ACME HTTP-01 challenges for Certbot / renewal.
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
        default_type "text/plain";
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen ${bind_ip}:443 ssl;
    server_name ${domain};

    # Tenant-specific footprint — required by post-provision curl verification.
    add_header X-Soviez-Tenant "${tenant_token}" always;

    ssl_certificate     ${crt_file};
    ssl_certificate_key ${key_file};

    client_max_body_size 512M;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    location / {
        proxy_pass http://127.0.0.1:${host_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_redirect off;
        # Re-assert tenant header inside location (nginx does not inherit add_header into locations that set others).
        add_header X-Soviez-Tenant "${tenant_token}" always;
    }

    location /websocket {
        proxy_pass http://127.0.0.1:${host_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 720s;
        add_header X-Soviez-Tenant "${tenant_token}" always;
    }
}
EOF

  ln -sfn "${site_file}" "${enabled_link}"
  # Clear safe Nginx catch-alls that can compete without an explicit server_name match path.
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  rm -f /etc/nginx/sites-enabled/000-default 2>/dev/null || true
  mkdir -p /var/www/html

  if ! nginx -t >>"${LOG_FILE}" 2>&1; then
    ui_error "Nginx site config failed for ${domain} — see ${LOG_FILE}"
    return 1
  fi
  systemctl reload nginx >>"${LOG_FILE}" 2>&1 || systemctl start nginx >>"${LOG_FILE}" 2>&1 || true
  log_file "Wrote Nginx site ${site_file} ssl_kind=${ssl_kind} bind=${bind_ip} tenant=${tenant_token} crt=${crt_file}"
}

# Baseline explicit-IP :443 (self-signed) → Certbot → LE rewrite or keep self-signed.
# Sets SSL_STATUS to letsencrypt | selfsigned. Always leaves PUBLIC_IP:443 online.
provision_tenant_https() {
  local domain="$1"
  local host_port="$2"
  local certbot_rc=0
  local bind_ip

  bind_ip="$(ensure_public_bind_ip)"
  SSL_STATUS="selfsigned"

  ui_wait "Writing baseline HTTPS Nginx site (${bind_ip}:443 self-signed) for ${domain}..."
  if ! write_nginx_site "${domain}" "${host_port}" "selfsigned"; then
    return 1
  fi
  ui_ok "Baseline HTTPS site live on ${bind_ip}:443 (self-signed / force-hijack)"

  if ! command -v certbot >/dev/null 2>&1; then
    ui_warn "Certbot not installed — keeping self-signed HTTPS. Run: sudo ./soviez.sh --init"
    SSL_STATUS="selfsigned"
    return 0
  fi

  if ! ensure_certbot_nginx_plugin; then
    ui_warn "Certbot nginx plugin unavailable — keeping self-signed HTTPS on ${bind_ip}:443"
    ensure_selfsigned_cert "${domain}" 0 || true
    write_nginx_site "${domain}" "${host_port}" "selfsigned" || return 1
    SSL_STATUS="selfsigned"
    return 0
  fi

  ui_wait "Requesting Let's Encrypt certificate for ${domain}..."
  set +e
  certbot --nginx -d "${domain}" --non-interactive --agree-tos \
    --register-unsafely-without-email --redirect >>"${LOG_FILE}" 2>&1
  certbot_rc=$?
  set -e

  if (( certbot_rc == 0 )) && [[ -f "$(ssl_le_fullchain_path "${domain}")" ]]; then
    ui_ok "Let's Encrypt issued for ${domain}"
    ui_wait "Locking Nginx to Let's Encrypt paths with explicit ${bind_ip} binds..."
    if write_nginx_site "${domain}" "${host_port}" "letsencrypt"; then
      SSL_STATUS="letsencrypt"
      ui_ok "HTTPS secured with Let's Encrypt on ${bind_ip}:443"
      return 0
    fi
    ui_warn "LE files exist but Nginx rewrite failed — restoring self-signed ${bind_ip}:443"
  else
    ui_warn "Let's Encrypt failed. Generating high-security Self-Signed fallback certificate..."
    log_file "WARN Certbot failed (rc=${certbot_rc}) for ${domain} — applying self-signed fallback"
  fi

  ensure_selfsigned_cert "${domain}" 1 || return 1
  if ! write_nginx_site "${domain}" "${host_port}" "selfsigned"; then
    return 1
  fi
  SSL_STATUS="selfsigned"
  ui_ok "Self-signed HTTPS fallback active on ${bind_ip}:443 (Cloudflare Full-compatible)"
  ui_warn "Using Cloudflare? Set SSL/TLS encryption mode to Full so the site opens securely."
  return 0
}

# Return 0 only when THIS tenant's Nginx answered (X-Soviez-Tenant header).
# Generic "odoo" body matches are insufficient — another Odoo on the same IP can 200 OK.
verify_tenant_https_http_code() {
  local domain="$1"
  local token hdrs code
  token="$(tenant_identity_token)"

  set +e
  hdrs="$(curl -k -sI --max-time 8 \
    -H "Host: ${domain}" \
    "https://${domain}/" 2>>"${LOG_FILE}")"
  local curl_rc=$?
  set -e

  code="$(printf '%s\n' "${hdrs}" | head -n1 | awk '{print $2}')"
  LAST_HTTPS_CODE="${code:-}"
  log_file "HTTPS verify ${domain} curl_rc=${curl_rc} http_code=${code:-} expect=X-Soviez-Tenant: ${token}"

  if (( curl_rc != 0 )) || [[ -z "${hdrs}" ]]; then
    return 1
  fi

  # Strict tenant header — must match soviez_$INDEX exactly (anti default-server / sibling Odoo).
  if ! printf '%s\n' "${hdrs}" | grep -Fiq "X-Soviez-Tenant: ${token}"; then
    log_file "HTTPS verify ${domain}: missing tenant header X-Soviez-Tenant: ${token} (HTTP ${code:-(none)}) — routing hijack / default server"
    log_file "HTTPS verify ${domain}: headers received: $(printf '%s' "${hdrs}" | tr '\n' '|' | head -c 500)"
    return 1
  fi

  case "${code}" in
    200|301|302|303|307|308|404|"")
      return 0
      ;;
    *)
      # Header matched our vhost — routing is correct even if upstream status is unexpected.
      log_file "HTTPS verify ${domain}: tenant header OK with HTTP ${code}"
      return 0
      ;;
  esac
}

# Detect non-Nginx processes holding :80 / :443 (Apache, etc.).
find_alien_http_process() {
  local ss_out=""
  if command -v ss >/dev/null 2>&1; then
    ss_out="$(ss -tulpn 2>/dev/null || true)"
  elif command -v netstat >/dev/null 2>&1; then
    ss_out="$(netstat -tulpn 2>/dev/null || true)"
  fi
  [[ -n "${ss_out}" ]] || return 1

  local line proc
  while IFS= read -r line; do
    [[ "${line}" =~ :(80|443)([[:space:]]|$) ]] || continue
    if printf '%s' "${line}" | grep -Eiq 'nginx'; then
      continue
    fi
    for proc in apache2 httpd apache lighttpd caddy traefik haproxy openresty litespeed; do
      if printf '%s' "${line}" | grep -Eiq "${proc}"; then
        printf '%s\n' "${proc}"
        return 0
      fi
    done
    if printf '%s' "${line}" | grep -Eq 'users:\(\("'; then
      proc="$(printf '%s' "${line}" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1)"
      if [[ -n "${proc}" && "${proc}" != "nginx" ]]; then
        printf '%s\n' "${proc}"
        return 0
      fi
    fi
  done <<< "${ss_out}"
  return 1
}

dump_port_capture_diagnostics() {
  local domain="$1"
  local bind_ip="$2"
  local site_file
  site_file="$(nginx_site_path "${domain}")"

  echo ""
  echo -e "${C_RED}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
  echo -e "${C_RED}${C_BOLD}  HTTPS routing still captured / unreachable for ${domain}${C_RESET}"
  echo -e "${C_RED}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
  echo -e "  Expected bind: ${C_BOLD}${bind_ip}:80${C_RESET} / ${C_BOLD}${bind_ip}:443${C_RESET}"
  echo -e "  Last HTTP code: ${C_BOLD}${LAST_HTTPS_CODE:-(none)}${C_RESET}"
  echo -e "  Expected header: ${C_BOLD}X-Soviez-Tenant: $(tenant_identity_token)${C_RESET}"
  echo -e "  ${C_DIM}Sibling Odoo on the same IP can return HTTP 200 — only the tenant header proves correct routing.${C_RESET}"
  echo ""
  echo -e "  ${C_BOLD}Listeners on :80 / :443:${C_RESET}"
  if command -v ss >/dev/null 2>&1; then
    ss -tulpn 2>/dev/null | grep -E ':(80|443)\b' || echo "    (none reported)"
  else
    netstat -tulpn 2>/dev/null | grep -E ':(80|443)\b' || echo "    (none reported)"
  fi
  echo ""
  echo -e "  ${C_BOLD}Soviez vhost listen lines:${C_RESET}"
  if [[ -f "${site_file}" ]]; then
    grep -E '^\s*listen' "${site_file}" | sed 's/^/    /' || true
  else
    echo "    (missing ${site_file})"
  fi
  echo ""
  echo -e "  ${C_BOLD}Other Nginx sites mentioning :443:${C_RESET}"
  grep -RsnE 'listen[[:space:]]+[^;]*443' /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/    /' | head -n 40 || true
  echo ""
  echo -e "  Full log: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo -e "  Emergency doctor: ${C_BOLD}sudo ./soviez.sh --formsetup${C_RESET} or ${C_BOLD}sudo ./soviez.sh --formssl ${domain}${C_RESET}"
  echo ""
}

# Soft clear of non-Soviez catch-all enabled sites that lack a specific server_name competition risk.
# Only removes classic default / debian placeholders — never Virtualmin managed sites.
clear_safe_nginx_catchalls() {
  local f
  for f in \
      /etc/nginx/sites-enabled/default \
      /etc/nginx/sites-enabled/000-default \
      /etc/nginx/sites-enabled/default.conf; do
    if [[ -e "${f}" ]]; then
      rm -f "${f}"
      log_file "Removed safe Nginx catch-all: ${f}"
    fi
  done
}

# Post-provision verification + self-heal. Called BEFORE welcome banner.
# Returns 0 on success; aborts process on alien webserver or unrecoverable capture.
verify_and_heal_tenant_https() {
  local domain="$1"
  local host_port="$2"
  local bind_ip alien site_file enabled_link
  LAST_HTTPS_CODE=""

  bind_ip="$(ensure_public_bind_ip)"
  site_file="$(nginx_site_path "${domain}")"
  enabled_link="/etc/nginx/sites-enabled/soviez-${domain}.conf"

  require_cmd curl

  ui_wait "Verifying HTTPS route https://${domain} (X-Soviez-Tenant: $(tenant_identity_token))..."
  if verify_tenant_https_http_code "${domain}"; then
    ui_ok "HTTPS verification passed — tenant header matched (HTTP ${LAST_HTTPS_CODE:-=})"
    return 0
  fi

  ui_warn "HTTPS verification failed (HTTP ${LAST_HTTPS_CODE:-(curl error)} / missing X-Soviez-Tenant: $(tenant_identity_token)) — healing..."
  log_file "WARN post-provision HTTPS verify failed for ${domain}; starting heal suite"

  # 1) Alien webservers occupying 80/443
  alien=""
  set +e
  alien="$(find_alien_http_process)"
  set -e
  if [[ -n "${alien}" ]]; then
    ui_error "⚠️ Error: This server is NOT fresh. Another web server (${alien}) is blocking Soviez. Please deploy on a fresh, clean OS."
    dump_port_capture_diagnostics "${domain}" "${bind_ip}"
    exit 1
  fi
  ui_ok "No alien webserver detected on :80/:443 (Nginx owns the sockets)"

  # 2) Panel override / catch-all drift — force re-apply explicit IP template
  ui_wait "Force-applying explicit ${bind_ip}:80/${bind_ip}:443 bind + hard Nginx restart..."
  clear_safe_nginx_catchalls
  if [[ ! -e "${enabled_link}" ]]; then
    ui_warn "Enabled symlink missing — recreating ${enabled_link}"
  fi
  if ! write_nginx_site "${domain}" "${host_port}" "${SSL_STATUS:-selfsigned}"; then
    ui_error "Failed to rewrite Nginx vhost during heal — see ${LOG_FILE}"
    dump_port_capture_diagnostics "${domain}" "${bind_ip}"
    exit 1
  fi
  systemctl restart nginx >>"${LOG_FILE}" 2>&1 || {
    ui_error "systemctl restart nginx failed — see ${LOG_FILE}"
    dump_port_capture_diagnostics "${domain}" "${bind_ip}"
    exit 1
  }
  sleep 2
  ui_ok "Nginx restarted with force-hijack binds on ${bind_ip}"

  ui_wait "Re-verifying HTTPS route https://${domain} (X-Soviez-Tenant)..."
  if verify_tenant_https_http_code "${domain}"; then
    ui_ok "HTTPS verification passed after heal — tenant header matched (HTTP ${LAST_HTTPS_CODE:-=})"
    return 0
  fi

  dump_port_capture_diagnostics "${domain}" "${bind_ip}"
  ui_error "Automated hijack attempts exhausted — https://${domain} is not serving X-Soviez-Tenant: $(tenant_identity_token)."
  exit 1
}

print_ssl_status_report() {
  local domain="$1"
  local mode="${2:-${SSL_STATUS}}"
  echo ""
  echo -e "  ${C_BOLD}SSL status for ${domain}${C_RESET}"
  case "${mode}" in
    letsencrypt)
      echo -e "     ${C_GREEN}✔ Let's Encrypt${C_RESET} — trusted public certificate active"
      echo -e "     ${C_DIM}$(ssl_le_fullchain_path "${domain}")${C_RESET}"
      ;;
    selfsigned)
      echo -e "     ${C_YELLOW}⚠ Self-Signed fallback${C_RESET} — optimized for Cloudflare ${C_BOLD}Full${C_RESET} mode"
      echo -e "     ${C_DIM}$(ssl_selfsigned_crt_path "${domain}")${C_RESET}"
      echo -e "     ${C_YELLOW}⚠️  SSL Note: Using Cloudflare? Ensure your Cloudflare SSL/TLS encryption mode is set to 'Full' so your site opens securely immediately!${C_RESET}"
      ;;
    *)
      echo -e "     ${C_DIM}Unknown / not provisioned${C_RESET}"
      ;;
  esac
  echo ""
}

find_env_path_by_domain() {
  local want="$1"
  local path domain
  shopt -s nullglob
  for path in \
      "${INSTANCE_ROOT}"/.soviez_*.env \
      "$(pwd)"/.soviez_*.env \
      "${INSTANCE_ROOT}/.soviez.env" \
      "$(pwd)/.soviez.env"; do
    [[ -f "${path}" ]] || continue
    domain="$(grep -E '^SOVIEZ_TENANT_DOMAIN=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    if [[ "${domain}" == "${want}" ]]; then
      shopt -u nullglob
      printf '%s\n' "${path}"
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

load_tenant_from_env_path() {
  local env_path="$1"
  ENV_FILE="${env_path}"
  load_env_file
  require_complete_env
  NETWORK_NAME="${SOVIEZ_NETWORK_NAME:-${NETWORK_NAME}}"
  DB_CONTAINER="${SOVIEZ_DB_CONTAINER:-${DB_CONTAINER}}"
  WEB_CONTAINER="${SOVIEZ_WEB_CONTAINER:-${WEB_CONTAINER}}"
  DB_VOLUME="${SOVIEZ_DB_VOLUME:-${DB_VOLUME}}"
  FILESTORE_VOLUME="${SOVIEZ_FILESTORE_VOLUME:-${FILESTORE_VOLUME}}"
  INSTANCE_INDEX="${SOVIEZ_INSTANCE_INDEX:-}"
  CUSTOM_ADDONS_HOST_PATH="${SOVIEZ_CUSTOM_ADDONS_HOST:-${CUSTOM_ADDONS_HOST_PATH}}"
  resolve_custom_addons_host_path
  TENANT_DOMAIN="${SOVIEZ_TENANT_DOMAIN:-}"
}

install_docker_engine() {
  if command -v docker >/dev/null 2>&1; then
    local ver major
    ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version | awk '{print $3}' | tr -d ',')"
    major="${ver%%.*}"
    if [[ "${major}" =~ ^[0-9]+$ ]] && (( major >= 20 )); then
      ui_ok "Docker ${ver} already installed"
      systemctl enable --now docker >>"${LOG_FILE}" 2>&1 || true
      return 0
    fi
    ui_warn "Docker ${ver} is outdated — upgrading via official convenience script..."
  else
    ui_wait "Docker not found — installing via official convenience script..."
  fi

  show_progress "Installing Docker Engine..." bash -c \
    'curl -fsSL https://get.docker.com | sh' || {
      ui_error "Docker installation failed — see ${LOG_FILE}"
      exit 1
    }
  systemctl enable --now docker >>"${LOG_FILE}" 2>&1
  ui_ok "Docker Engine ready"
}

ensure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    show_progress "Installing UFW..." apt-get install -y ufw || return 1
  fi
  # Open required ports BEFORE enabling (preserve SSH)
  ufw allow 22/tcp >>"${LOG_FILE}" 2>&1 || true
  ufw allow OpenSSH >>"${LOG_FILE}" 2>&1 || true
  ufw allow 80/tcp >>"${LOG_FILE}" 2>&1 || true
  ufw allow 443/tcp >>"${LOG_FILE}" 2>&1 || true
  ufw --force enable >>"${LOG_FILE}" 2>&1 || true
  ui_ok "UFW active — ports 22 / 80 / 443 allowed"
}

print_elite_welcome() {
  local domain="$1"
  local addons_path="$2"
  local admin_password="$3"
  local index="$4"

  clear 2>/dev/null || true
  echo ""
  echo -e "${C_GREEN}${C_BOLD}"
  cat <<'BANNER'
   ███████╗ ██████╗ ██╗   ██╗██╗███████╗███████╗
   ██╔════╝██╔═══██╗██║   ██║██║██╔════╝╚══███╔╝
   ███████╗██║   ██║██║   ██║██║█████╗    ███╔╝
   ╚════██║██║   ██║╚██╗ ██╔╝██║██╔══╝   ███╔╝
   ███████║╚██████╔╝ ╚████╔╝ ██║███████╗███████╗
   ╚══════╝ ╚═════╝   ╚═══╝  ╚═╝╚══════╝╚══════╝
            E R P   E C O S Y S T E M
BANNER
  echo -e "${C_RESET}"
  echo -e "  ${C_GREEN}✔${C_RESET}  ${C_BOLD}Welcome to the Soviez ERP ecosystem!${C_RESET}"
  echo -e "  ${C_GREEN}✔${C_RESET}  Tenant instance #${index} is live and secured."
  echo ""
  echo -e "  ${C_BOLD}Live URL${C_RESET}"
  echo -e "     ${C_CYAN}https://${domain}${C_RESET}"
  echo ""
  echo -e "  ${C_BOLD}Custom addons folder${C_RESET}"
  echo -e "     ${C_CYAN}${addons_path}${C_RESET}"
  echo -e "     ${C_DIM}Drop Odoo modules here, then refresh Apps or run ./soviez.sh --update${C_RESET}"
  print_ssl_status_report "${domain}" "${SSL_STATUS:-}"
  if [[ "${SSL_STATUS:-}" == "selfsigned" ]]; then
    echo -e "  ${C_DIM}Re-attempt Let's Encrypt later: sudo ./soviez.sh --formssl ${domain}${C_RESET}"
    echo ""
  fi
  print_master_password_alert \
    "${admin_password}" \
    "INSTANCE #${index} — DATABASE MASTER PASSWORD (SAVE THIS NOW)"
  echo -e "  ${C_DIM}Full setup log: ${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: init — host environment only
# ===========================================================================
mode_init() {
  require_root --init
  ensure_log_file
  export DEBIAN_FRONTEND=noninteractive

  print_border_box "Soviez ERP — Host Initialization" \
    "Preparing a production-ready Ubuntu/Debian appliance." \
    "Containers are NOT launched in this mode." \
    "After success, provision tenants with: ./soviez.sh --new"

  show_progress "Updating system components..." bash -c \
    'apt-get update -y && apt-get upgrade -y' || {
      ui_error "System update failed — see ${LOG_FILE}"
      exit 1
    }

  show_progress "Installing base utilities (curl, ca-certificates)..." \
    apt-get install -y curl ca-certificates gnupg lsb-release || true

  install_docker_engine

  if ! command -v nginx >/dev/null 2>&1; then
    show_progress "Installing Nginx..." apt-get install -y nginx || exit 1
  else
    ui_ok "Nginx already installed"
  fi
  systemctl enable --now nginx >>"${LOG_FILE}" 2>&1 || true
  show_progress "Applying Nginx ERP traffic limits..." configure_nginx_global_limits

  show_progress "Installing Certbot + python3-certbot-nginx..." bash -c \
    'apt-get install -y certbot python3-certbot-nginx' || exit 1
  ensure_certbot_nginx_plugin || exit 1

  ensure_ufw

  print_green_success "Host environment successfully initialized!"
  echo -e "  You can now provision instances using:"
  echo -e "    ${C_BOLD}sudo ./soviez.sh --new${C_RESET}"
  echo -e "  Log file: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: new — tenant provisioning
# ===========================================================================
mode_new() {
  require_root --new
  ensure_log_file
  require_cmd docker
  require_cmd python3
  ensure_host_ledger_dir

  if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
    ui_error "Host not initialized. Run first: sudo ./soviez.sh --init"
    exit 1
  fi

  local public_ip next_index
  public_ip="$(detect_public_ip)"
  PUBLIC_IP="${public_ip}"

  print_border_box "Welcome to Soviez ERP Tenant Provisioning" \
    "To proceed, you need a domain or subdomain pointed to this server's" \
    "Public IP: ${C_BOLD}${public_ip}${C_RESET}" \
    "" \
    "This wizard will create an isolated container stack + HTTPS site."

  prompt_domain_confirmed
  dns_validation_loop "${public_ip}" "${TENANT_DOMAIN}"

  mkdir -p "${INSTANCE_ROOT}"
  next_index="$(find_next_instance_index)"
  apply_topology_indexed "${next_index}"

  if [[ -f "${ENV_FILE}" ]]; then
    ui_error "Target environment already exists: ${ENV_FILE}"
    exit 1
  fi

  ui_info "Provisioning isolated tenant index=${next_index} (${WEB_CONTAINER})"
  prompt_resource_tuning_on_new
  ensure_custom_addons_dir

  SOVIEZ_CONTAINER_MAC="$(generate_mac)"
  SOVIEZ_DB_PASSWORD="$(generate_password)"
  SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
  SOVIEZ_HOST_PORT="$(find_free_host_port "${MULTI_PORT_START}")"

  cat > "${ENV_FILE}" <<EOF
SOVIEZ_INSTANCE_INDEX=${next_index}
SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}
SOVIEZ_CONTAINER_MAC=${SOVIEZ_CONTAINER_MAC}
SOVIEZ_DB_PASSWORD=${SOVIEZ_DB_PASSWORD}
SOVIEZ_ADMIN_PASSWORD=${SOVIEZ_ADMIN_PASSWORD}
SOVIEZ_NETWORK_NAME=${NETWORK_NAME}
SOVIEZ_DB_CONTAINER=${DB_CONTAINER}
SOVIEZ_WEB_CONTAINER=${WEB_CONTAINER}
SOVIEZ_DB_VOLUME=${DB_VOLUME}
SOVIEZ_FILESTORE_VOLUME=${FILESTORE_VOLUME}
SOVIEZ_CUSTOM_ADDONS_HOST=${CUSTOM_ADDONS_HOST_PATH}
SOVIEZ_CUSTOM_ADDONS_MOUNT=${CUSTOM_ADDONS_CONTAINER_PATH}
SOVIEZ_TENANT_DOMAIN=${TENANT_DOMAIN}
SOVIEZ_PUBLIC_IP=${public_ip}
SOVIEZ_AUTO_TUNE=${AUTO_TUNE_ON_NEW}
EOF
  chmod 600 "${ENV_FILE}"

  show_progress "Pulling container images..." bash -c \
    "docker pull '${APP_IMAGE}' && docker pull '${DB_IMAGE}'"

  show_progress "Creating network and volumes..." ensure_network_and_volumes
  show_progress "Starting PostgreSQL (${DB_CONTAINER})..." ensure_postgres_container

  if container_exists "${WEB_CONTAINER}"; then
    docker rm -f "${WEB_CONTAINER}" >/dev/null 2>&1 || true
  fi
  show_progress "Launching Soviez ERP (${WEB_CONTAINER})..." launch_web_container

  if ! provision_tenant_https "${TENANT_DOMAIN}" "${SOVIEZ_HOST_PORT}"; then
    ui_error "HTTPS provisioning failed — see ${LOG_FILE}"
    exit 1
  fi
  persist_env_key "SOVIEZ_SSL_MODE" "${SSL_STATUS}"
  persist_env_key "SOVIEZ_PUBLIC_IP" "${PUBLIC_IP}"
  verify_and_heal_tenant_https "${TENANT_DOMAIN}" "${SOVIEZ_HOST_PORT}"

  if (( AUTO_TUNE_ON_NEW == 1 )); then
    ui_info "Running intelligent auto-configuration for ${WEB_CONTAINER}..."
    compute_allocation_for_tenant "${WEB_CONTAINER}"
    apply_tenant_resource_tuning || ui_warn "Auto-tuning failed — retry with: sudo ./soviez.sh --formworkers ${WEB_CONTAINER}"
  fi

  print_elite_welcome \
    "${TENANT_DOMAIN}" \
    "${CUSTOM_ADDONS_HOST_PATH}" \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "${next_index}"
}

# ===========================================================================
# MODE: formworkers — intelligent resource tuning for an existing tenant
# ===========================================================================
mode_formworkers() {
  require_root --formworkers
  ensure_log_file
  require_cmd docker

  if [[ -z "${FORMWORKERS_TENANT_REF}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --formworkers <tenant>"
    ui_error "Example: sudo ./soviez.sh --formworkers soviez-web-1"
    exit 1
  fi

  load_tenant_topology_from_ref "${FORMWORKERS_TENANT_REF}"
  resolve_custom_addons_host_path
  require_complete_env

  if ! container_exists "${WEB_CONTAINER}"; then
    ui_error "Tenant web container not found: ${WEB_CONTAINER}"
    ui_error "Provision the tenant first with: sudo ./soviez.sh --new"
    exit 1
  fi

  print_border_box "Soviez ERP — Intelligent Resource Tuning" \
    "Tenant: ${C_BOLD}${WEB_CONTAINER}${C_RESET}" \
    "Env: ${ENV_FILE}" \
    "" \
    "Safe restart pipeline: stop web → recycle DB engine (volume kept) →" \
    "update odoo.conf → apply Docker limits → start web."

  compute_allocation_for_tenant "${WEB_CONTAINER}"
  apply_tenant_resource_tuning
}

# ===========================================================================
# MODE: formsetup — idempotent resume / heal of latest half-configured tenant
# ===========================================================================
mode_formsetup() {
  require_root --formsetup
  ensure_log_file
  require_cmd docker
  require_cmd python3
  ensure_host_ledger_dir

  if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
    ui_error "Host not initialized. Run first: sudo ./soviez.sh --init"
    exit 1
  fi

  local target_index
  target_index="$(select_formsetup_index)"
  if (( target_index < 1 )); then
    ui_error "No tenant environment sheet found. Provision with: sudo ./soviez.sh --new"
    exit 1
  fi

  apply_topology_indexed "${target_index}"
  if [[ ! -f "${ENV_FILE}" ]]; then
    ui_error "Missing environment sheet for index ${target_index}: ${ENV_FILE}"
    exit 1
  fi

  load_env_file
  require_complete_env

  NETWORK_NAME="${SOVIEZ_NETWORK_NAME:-${NETWORK_NAME}}"
  DB_CONTAINER="${SOVIEZ_DB_CONTAINER:-${DB_CONTAINER}}"
  WEB_CONTAINER="${SOVIEZ_WEB_CONTAINER:-${WEB_CONTAINER}}"
  DB_VOLUME="${SOVIEZ_DB_VOLUME:-${DB_VOLUME}}"
  FILESTORE_VOLUME="${SOVIEZ_FILESTORE_VOLUME:-${FILESTORE_VOLUME}}"
  INSTANCE_INDEX="${SOVIEZ_INSTANCE_INDEX:-${target_index}}"
  CUSTOM_ADDONS_HOST_PATH="${SOVIEZ_CUSTOM_ADDONS_HOST:-${CUSTOM_ADDONS_HOST_PATH}}"
  resolve_custom_addons_host_path
  TENANT_DOMAIN="${SOVIEZ_TENANT_DOMAIN:-}"

  if [[ -z "${TENANT_DOMAIN}" ]]; then
    ui_error "${ENV_FILE} has no SOVIEZ_TENANT_DOMAIN — cannot resume Nginx/SSL."
    exit 1
  fi

  PUBLIC_IP="${SOVIEZ_PUBLIC_IP:-}"
  ensure_public_bind_ip >/dev/null
  persist_env_key "SOVIEZ_PUBLIC_IP" "${PUBLIC_IP}"

  print_border_box "Soviez ERP — Form Setup Recovery" \
    "Resuming tenant index ${C_BOLD}#${INSTANCE_INDEX}${C_RESET} (${WEB_CONTAINER})" \
    "Domain: ${C_BOLD}${TENANT_DOMAIN}${C_RESET}" \
    "Env: ${ENV_FILE}" \
    "" \
    "Pipeline is idempotent: existing assets are kept; Nginx/SSL are rebuilt."

  ui_info "Healing half-configured instance index=${INSTANCE_INDEX}"
  ensure_custom_addons_dir

  resume_network_and_volumes
  resume_postgres_container
  resume_web_container

  ui_wait "Regenerating Nginx + HTTPS for ${TENANT_DOMAIN}..."
  if ! provision_tenant_https "${TENANT_DOMAIN}" "${SOVIEZ_HOST_PORT}"; then
    ui_error "Nginx/SSL recovery failed — see ${LOG_FILE}"
    exit 1
  fi
  persist_env_key "SOVIEZ_SSL_MODE" "${SSL_STATUS}"
  persist_env_key "SOVIEZ_PUBLIC_IP" "${PUBLIC_IP}"
  ui_ok "HTTPS pipeline complete for ${TENANT_DOMAIN} (${SSL_STATUS})"
  verify_and_heal_tenant_https "${TENANT_DOMAIN}" "${SOVIEZ_HOST_PORT}"

  print_elite_welcome \
    "${TENANT_DOMAIN}" \
    "${CUSTOM_ADDONS_HOST_PATH}" \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "${INSTANCE_INDEX}"
}

# ===========================================================================
# MODE: formssl — diagnose / repair tenant HTTPS (LE or self-signed fallback)
# ===========================================================================
mode_formssl() {
  require_root --formssl
  ensure_log_file
  require_cmd openssl

  if ! command -v nginx >/dev/null 2>&1; then
    ui_error "Nginx not installed. Run first: sudo ./soviez.sh --init"
    exit 1
  fi

  local target_index env_path domain host_port site_file active_crt issuer has_443

  if [[ -n "${FORMSSL_DOMAIN}" ]]; then
    TENANT_DOMAIN="$(printf '%s' "${FORMSSL_DOMAIN}" | tr '[:upper:]' '[:lower:]')"
    TENANT_DOMAIN="${TENANT_DOMAIN#http://}"
    TENANT_DOMAIN="${TENANT_DOMAIN#https://}"
    TENANT_DOMAIN="${TENANT_DOMAIN%%/*}"
    if ! env_path="$(find_env_path_by_domain "${TENANT_DOMAIN}")"; then
      ui_error "No environment sheet found for domain: ${TENANT_DOMAIN}"
      exit 1
    fi
    load_tenant_from_env_path "${env_path}"
  else
    target_index="$(select_formsetup_index)"
    if (( target_index < 1 )); then
      target_index="$(find_highest_instance_index)"
    fi
    if (( target_index < 1 )); then
      ui_error "No tenant found. Provision with: sudo ./soviez.sh --new"
      exit 1
    fi
    apply_topology_indexed "${target_index}"
    if [[ ! -f "${ENV_FILE}" ]]; then
      ui_error "Missing environment sheet: ${ENV_FILE}"
      exit 1
    fi
    load_tenant_from_env_path "${ENV_FILE}"
  fi

  domain="${TENANT_DOMAIN:-}"
  host_port="${SOVIEZ_HOST_PORT:-}"
  if [[ -z "${domain}" || -z "${host_port}" ]]; then
    ui_error "Env sheet incomplete (need SOVIEZ_TENANT_DOMAIN + SOVIEZ_HOST_PORT)."
    exit 1
  fi

  PUBLIC_IP="${SOVIEZ_PUBLIC_IP:-}"
  ensure_public_bind_ip >/dev/null
  persist_env_key "SOVIEZ_PUBLIC_IP" "${PUBLIC_IP}"

  site_file="$(nginx_site_path "${domain}")"

  print_border_box "Soviez ERP — SSL Form Repair" \
    "Domain: ${C_BOLD}${domain}${C_RESET}" \
    "Upstream: 127.0.0.1:${host_port}" \
    "Env: ${ENV_FILE}" \
    "" \
    "Diagnose → Certbot attempt → Let's Encrypt or self-signed :443 fallback"

  ui_info "Diagnosing Nginx / certificate state..."

  if [[ -f "${site_file}" ]]; then
    ui_ok "Nginx vhost present: ${site_file}"
  else
    ui_warn "Nginx vhost missing — will be rewritten"
  fi

  if nginx_site_has_443 "${domain}"; then
    ui_ok "Port 443 listener configured in vhost"
    has_443=1
  else
    ui_warn "Port 443 listener MISSING — Virtualmin may be capturing HTTPS"
    has_443=0
  fi

  if [[ -f "$(ssl_le_fullchain_path "${domain}")" ]]; then
    active_crt="$(ssl_le_fullchain_path "${domain}")"
    issuer="$(cert_issuer_summary "${active_crt}")"
    if cert_is_letsencrypt_file "${active_crt}"; then
      ui_ok "Let's Encrypt material present — issuer: ${issuer}"
    else
      ui_warn "LE path exists but issuer is unexpected: ${issuer}"
    fi
  elif [[ -f "$(ssl_selfsigned_crt_path "${domain}")" ]]; then
    active_crt="$(ssl_selfsigned_crt_path "${domain}")"
    issuer="$(cert_issuer_summary "${active_crt}")"
    ui_warn "Self-signed material present — issuer: ${issuer}"
  else
    ui_warn "No certificate files found on disk for ${domain}"
  fi

  if ! provision_tenant_https "${domain}" "${host_port}"; then
    ui_error "SSL repair failed — see ${LOG_FILE}"
    exit 1
  fi
  persist_env_key "SOVIEZ_SSL_MODE" "${SSL_STATUS}"
  persist_env_key "SOVIEZ_PUBLIC_IP" "${PUBLIC_IP}"
  verify_and_heal_tenant_https "${domain}" "${host_port}"

  print_green_success "SSL form repair complete for ${domain}"
  print_ssl_status_report "${domain}" "${SSL_STATUS}"
  if [[ "${SSL_STATUS}" == "letsencrypt" ]]; then
    echo -e "  ${C_GREEN}True Let's Encrypt SSL is active.${C_RESET} Browsers will trust https://${domain}"
  else
    echo -e "  ${C_DIM}Tip: Switch Cloudflare to DNS-only (grey cloud) temporarily, then re-run:${C_RESET}"
    echo -e "    ${C_BOLD}sudo ./soviez.sh --formssl ${domain}${C_RESET}"
  fi
  echo -e "  ${C_DIM}Log: ${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: update — pull image + recycle web runners (all envs)
# ===========================================================================
mode_update() {
  ensure_log_file
  require_cmd docker
  require_cmd python3
  ensure_host_ledger_dir

  local env_path
  local -a env_files=()

  # Indexed tenants
  shopt -s nullglob
  for env_path in "${INSTANCE_ROOT}"/.soviez_*.env "$(pwd)"/.soviez_*.env; do
    [[ -f "${env_path}" ]] || continue
    env_files+=("${env_path}")
  done
  shopt -u nullglob

  # Legacy primary (optional)
  for env_path in "${INSTANCE_ROOT}/.soviez.env" "$(pwd)/.soviez.env"; do
    if [[ -f "${env_path}" ]]; then
      env_files+=("${env_path}")
    fi
  done

  if ((${#env_files[@]} == 0)); then
    ui_error "No Soviez environments found. Provision one with: sudo ./soviez.sh --new"
    exit 1
  fi

  show_progress "Pulling ${APP_IMAGE}..." docker pull "${APP_IMAGE}"

  local processed=()
  for env_path in "${env_files[@]}"; do
    # Deduplicate by realpath when both INSTANCE_ROOT and cwd point at same file
    local real
    real="$(readlink -f "${env_path}" 2>/dev/null || echo "${env_path}")"
    local skip=0
    local prev
    for prev in "${processed[@]:-}"; do
      if [[ "${prev}" == "${real}" ]]; then
        skip=1
        break
      fi
    done
    (( skip == 1 )) && continue
    processed+=("${real}")

    ENV_FILE="${env_path}"
    ui_info "Updating instance from ${ENV_FILE}"
    load_env_file
    require_complete_env

    NETWORK_NAME="${SOVIEZ_NETWORK_NAME:-${NETWORK_NAME}}"
    DB_CONTAINER="${SOVIEZ_DB_CONTAINER:-${DB_CONTAINER}}"
    WEB_CONTAINER="${SOVIEZ_WEB_CONTAINER:-${WEB_CONTAINER}}"
    DB_VOLUME="${SOVIEZ_DB_VOLUME:-${DB_VOLUME}}"
    FILESTORE_VOLUME="${SOVIEZ_FILESTORE_VOLUME:-${FILESTORE_VOLUME}}"
    INSTANCE_INDEX="${SOVIEZ_INSTANCE_INDEX:-}"
    CUSTOM_ADDONS_HOST_PATH="${SOVIEZ_CUSTOM_ADDONS_HOST:-}"
    resolve_custom_addons_host_path

    if ! container_running "${DB_CONTAINER}"; then
      if container_exists "${DB_CONTAINER}"; then
        docker start "${DB_CONTAINER}" >/dev/null
      else
        ui_error "Database container '${DB_CONTAINER}' missing — skip ${ENV_FILE}"
        continue
      fi
    fi
    wait_for_postgres || continue

    ui_wait "Stopping web runner ${WEB_CONTAINER}..."
    docker stop "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
    docker rm -f "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true

    if ! show_progress "Schema upgrade (${WEB_CONTAINER})..." run_schema_upgrades; then
      ui_error "Upgrade aborted for ${WEB_CONTAINER} — left offline. Fix and re-run --update."
      continue
    fi

    show_progress "Relaunching ${WEB_CONTAINER}..." launch_web_container
    ui_ok "Recycled ${WEB_CONTAINER} on ${APP_IMAGE}"
  done

  print_green_success "Update complete — web runners recycled on ${APP_IMAGE}"
  echo -e "  Log: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: recover — rotate admin password + recycle one web runner
# ===========================================================================
mode_recover() {
  ensure_log_file
  require_cmd docker
  require_cmd python3

  apply_topology_primary
  if [[ ! -f "${ENV_FILE}" ]]; then
    # Fall back to highest indexed tenant if no primary
    local idx
    idx="$(find_next_instance_index)"
    if (( idx > 1 )); then
      apply_topology_indexed $((idx - 1))
    fi
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    ui_error "No Soviez installation found to recover."
    exit 1
  fi

  load_env_file
  NETWORK_NAME="${SOVIEZ_NETWORK_NAME:-${NETWORK_NAME}}"
  DB_CONTAINER="${SOVIEZ_DB_CONTAINER:-${DB_CONTAINER}}"
  WEB_CONTAINER="${SOVIEZ_WEB_CONTAINER:-${WEB_CONTAINER}}"
  DB_VOLUME="${SOVIEZ_DB_VOLUME:-${DB_VOLUME}}"
  FILESTORE_VOLUME="${SOVIEZ_FILESTORE_VOLUME:-${FILESTORE_VOLUME}}"
  INSTANCE_INDEX="${SOVIEZ_INSTANCE_INDEX:-}"
  CUSTOM_ADDONS_HOST_PATH="${SOVIEZ_CUSTOM_ADDONS_HOST:-}"
  resolve_custom_addons_host_path

  if [[ -z "${SOVIEZ_CONTAINER_MAC:-}" || -z "${SOVIEZ_DB_PASSWORD:-}" || -z "${SOVIEZ_HOST_PORT:-}" ]]; then
    ui_error "${ENV_FILE} is incomplete — cannot recover master password."
    exit 1
  fi

  ui_info "Rotating Database Master Password..."
  SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
  persist_env_key "SOVIEZ_ADMIN_PASSWORD" "${SOVIEZ_ADMIN_PASSWORD}"
  load_env_file

  ensure_network_and_volumes
  docker rm -f "${WEB_CONTAINER}" 2>/dev/null || true
  show_progress "Pulling ${APP_IMAGE}..." docker pull "${APP_IMAGE}"
  show_progress "Recycling ${WEB_CONTAINER}..." launch_web_container

  print_master_password_alert \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "MASTER PASSWORD RESET — APPLICATION LAYER RECYCLED"
  ui_ok "Master Password reset. Volumes preserved."
}

# ===========================================================================
# Staging helpers (--stage / --dropstage)
# ===========================================================================
assert_safe_dbname() {
  local name="$1"
  if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    ui_error "Refusing unsafe database name: ${name}"
    exit 1
  fi
}

parse_tenant_index_from_ref() {
  local ref="$1"
  ref="$(strip_trailing_hyphens "${ref}")"
  ref="${ref,,}"
  ref="${ref//_/-}"

  if [[ "${ref}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${ref}"
    return 0
  fi
  if [[ "${ref}" =~ ^soviez-web-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${ref}" =~ ^soviez-db-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${ref}" =~ ^soviez-([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "${ref}" == "soviez-web" || "${ref}" == "soviez-db" || "${ref}" == "primary" || "${ref}" == "soviez" ]]; then
    printf '%s\n' "primary"
    return 0
  fi
  return 1
}

load_tenant_topology_from_ref() {
  local ref="$1"
  local idx env_candidate

  if ! idx="$(parse_tenant_index_from_ref "${ref}")"; then
    ui_error "Cannot resolve tenant reference: ${ref}"
    ui_error "Try: soviez-web-1 | soviez_web_1 | 1 | soviez-web"
    exit 1
  fi

  if [[ "${idx}" == "primary" ]]; then
    apply_topology_primary
  else
    apply_topology_indexed "${idx}"
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    for env_candidate in \
        "${INSTANCE_ROOT}/.soviez_${idx}.env" \
        "$(pwd)/.soviez_${idx}.env" \
        "${INSTANCE_ROOT}/.soviez.env" \
        "$(pwd)/.soviez.env"; do
      if [[ -f "${env_candidate}" ]]; then
        ENV_FILE="${env_candidate}"
        break
      fi
    done
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    ui_error "Environment sheet not found for tenant '${ref}' (looked for ${ENV_FILE})"
    exit 1
  fi

  load_env_file
  require_complete_env

  NETWORK_NAME="${SOVIEZ_NETWORK_NAME:-${NETWORK_NAME}}"
  DB_CONTAINER="${SOVIEZ_DB_CONTAINER:-${DB_CONTAINER}}"
  WEB_CONTAINER="${SOVIEZ_WEB_CONTAINER:-${WEB_CONTAINER}}"
  DB_VOLUME="${SOVIEZ_DB_VOLUME:-${DB_VOLUME}}"
  FILESTORE_VOLUME="${SOVIEZ_FILESTORE_VOLUME:-${FILESTORE_VOLUME}}"
  INSTANCE_INDEX="${SOVIEZ_INSTANCE_INDEX:-${INSTANCE_INDEX}}"
  CUSTOM_ADDONS_HOST_PATH="${SOVIEZ_CUSTOM_ADDONS_HOST:-${CUSTOM_ADDONS_HOST_PATH}}"

  ui_ok "Resolved tenant env ${ENV_FILE}"
  ui_info "DB=${DB_CONTAINER}  WEB=${WEB_CONTAINER}  FILESTORE=${FILESTORE_VOLUME}"
}

pg_terminate_db_connections() {
  local dbname="$1"
  assert_safe_dbname "${dbname}"
  docker exec "${DB_CONTAINER}" \
    psql -U "${DB_APP_USER}" -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT pg_terminate_backend(pg_stat_activity.pid)
     FROM pg_stat_activity
     WHERE pg_stat_activity.datname = '${dbname}'
       AND pid <> pg_backend_pid();" >>"${LOG_FILE}" 2>&1 || true
}

pg_database_exists() {
  local dbname="$1"
  local found
  found="$(docker exec "${DB_CONTAINER}" \
    psql -U "${DB_APP_USER}" -d postgres -Atc \
    "SELECT 1 FROM pg_database WHERE datname = '${dbname}' LIMIT 1;" 2>/dev/null || true)"
  [[ "${found}" == "1" ]]
}

# Returns ir_config_parameter value for database.is_neutralized (empty if missing).
pg_is_neutralized_value() {
  local dbname="$1"
  docker exec "${DB_CONTAINER}" \
    psql -U "${DB_APP_USER}" -d "${dbname}" -Atc \
    "SELECT value FROM ir_config_parameter WHERE key = 'database.is_neutralized' LIMIT 1;" \
    2>/dev/null || true
}

bytes_to_gb_str() {
  local bytes="${1:-0}"
  awk -v b="${bytes}" 'BEGIN { printf "%.2f", (b + 0) / (1024 * 1024 * 1024) }'
}

tenant_index_label() {
  if [[ -n "${INSTANCE_INDEX:-}" ]]; then
    printf '%s\n' "${INSTANCE_INDEX}"
  elif [[ -n "${SOVIEZ_INSTANCE_INDEX:-}" ]]; then
    printf '%s\n' "${SOVIEZ_INSTANCE_INDEX}"
  else
    printf '%s\n' "0"
  fi
}

# Filestore lives on Docker volume at /fs/<db>; web mount is usually data-dir/filestore.
measure_filestore_bytes() {
  local dbname="$1"
  local size="" path

  for path in \
      "/root/.local/share/Odoo/filestore/${dbname}" \
      "/var/lib/odoo/filestore/${dbname}"; do
    size="$(docker exec "${WEB_CONTAINER}" \
      du -s -b "${path}" 2>/dev/null | awk '{print $1}' || true)"
    if [[ -n "${size}" && "${size}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${size}"
      return 0
    fi
  done

  size="$(docker run --rm \
      -v "${FILESTORE_VOLUME}:/fs:ro" \
      alpine:3.20 \
      sh -c "du -s -b /fs/${dbname} 2>/dev/null | cut -f1" 2>/dev/null || true)"
  if [[ -n "${size}" && "${size}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "${size}"
    return 0
  fi
  printf '%s\n' "0"
}

lookup_domain_for_index() {
  local idx="$1"
  local path domain=""
  local -a candidates=()

  if [[ "${idx}" == "0" || "${idx}" == "primary" ]]; then
    candidates+=(
      "${INSTANCE_ROOT:-}/.soviez.env"
      "$(pwd)/.soviez.env"
      "/root/.soviez.env"
    )
  fi
  candidates+=(
    "/root/.soviez_${idx}.env"
    "${INSTANCE_ROOT:-}/.soviez_${idx}.env"
    "$(pwd)/.soviez_${idx}.env"
  )

  for path in "${candidates[@]}"; do
    [[ -f "${path}" ]] || continue
    domain="$(grep -E '^SOVIEZ_TENANT_DOMAIN=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    domain="${domain//$'\r'/}"
    domain="${domain#\"}"
    domain="${domain%\"}"
    domain="${domain#\'}"
    domain="${domain%\'}"
    if [[ -n "${domain}" ]]; then
      printf '%s\n' "${domain}"
      return 0
    fi
  done
  printf '%s\n' "[Malformed / No Domain]"
}

assert_backup_disk_space() {
  local db_size="$1"
  local filestore_size="$2"
  local estimated free needed_min free_gb need_gb

  estimated=$((db_size + filestore_size))
  free="$(df -B1 "${BACKUP_ROOT}" | tail -n 1 | awk '{print $4}')"
  if [[ -z "${free}" || ! "${free}" =~ ^[0-9]+$ ]]; then
    echo -e "${C_RED}🚨 [ERROR] Backup Blocked! Unable to measure free space on ${BACKUP_ROOT}.${C_RESET}" >&2
    exit 1
  fi

  if (( free - estimated < BACKUP_SAFETY_MARGIN_BYTES )); then
    needed_min=$((estimated + BACKUP_SAFETY_MARGIN_BYTES))
    need_gb="$(bytes_to_gb_str "${needed_min}")"
    free_gb="$(bytes_to_gb_str "${free}")"
    echo -e "${C_RED}🚨 [ERROR] Backup Blocked! Insufficient disk space. To safely run this backup and preserve a 5 GB host buffer, we need at least ${need_gb} GB free. Only ${free_gb} GB is available.${C_RESET}" >&2
    log_file "ERROR Backup blocked: free=${free} estimated=${estimated} margin=${BACKUP_SAFETY_MARGIN_BYTES}"
    exit 1
  fi

  ui_ok "Disk safety check passed (need ≥$(bytes_to_gb_str "$((estimated + BACKUP_SAFETY_MARGIN_BYTES))") GB free incl. 5 GB buffer; have $(bytes_to_gb_str "${free}") GB)"
}

clone_filestore_dir() {
  local source_db="$1"
  local target_db="$2"

  ui_wait "Cloning filestore ${source_db} → ${target_db} on volume ${FILESTORE_VOLUME}..."
  # Prefer docker-managed copy (works even when host Mountpoint is root-only).
  if ! docker run --rm \
      -v "${FILESTORE_VOLUME}:/fs" \
      alpine:3.20 \
      sh -c "set -e
        if [ ! -d /fs/${source_db} ]; then
          echo \"Source filestore missing: /fs/${source_db}\" >&2
          exit 1
        fi
        rm -rf /fs/${target_db}
        cp -a /fs/${source_db} /fs/${target_db}
        # Odoo conventional uid/gid inside ERP images
        chown -R 101:101 /fs/${target_db} 2>/dev/null || chown -R odoo:odoo /fs/${target_db} 2>/dev/null || true
      " >>"${LOG_FILE}" 2>&1; then
    # Fallback: host volume mountpoint
    local mp
    mp="$(docker volume inspect -f '{{.Mountpoint}}' "${FILESTORE_VOLUME}" 2>/dev/null || true)"
    if [[ -z "${mp}" || ! -d "${mp}/${source_db}" ]]; then
      ui_error "Filestore clone failed for ${source_db} → ${target_db} — see ${LOG_FILE}"
      return 1
    fi
    rm -rf "${mp}/${target_db}"
    cp -a "${mp}/${source_db}" "${mp}/${target_db}"
    chown -R 101:101 "${mp}/${target_db}" 2>/dev/null || chown -R odoo:odoo "${mp}/${target_db}" 2>/dev/null || true
  fi
  ui_ok "Filestore cloned to ${target_db}"
}

remove_filestore_dir() {
  local dbname="$1"
  ui_wait "Removing filestore directory ${dbname} on ${FILESTORE_VOLUME}..."
  if docker run --rm \
      -v "${FILESTORE_VOLUME}:/fs" \
      alpine:3.20 \
      sh -c "rm -rf /fs/${dbname}" >>"${LOG_FILE}" 2>&1; then
    ui_ok "Filestore ${dbname} removed"
    return 0
  fi
  local mp
  mp="$(docker volume inspect -f '{{.Mountpoint}}' "${FILESTORE_VOLUME}" 2>/dev/null || true)"
  if [[ -n "${mp}" && -e "${mp}/${dbname}" ]]; then
    rm -rf "${mp}/${dbname}"
    ui_ok "Filestore ${dbname} removed (host path)"
    return 0
  fi
  ui_warn "Filestore path for ${dbname} not found — nothing to delete"
}

mark_database_neutralized_sql() {
  local dbname="$1"
  assert_safe_dbname "${dbname}"
  docker exec "${DB_CONTAINER}" \
    psql -U "${DB_APP_USER}" -d "${dbname}" -v ON_ERROR_STOP=1 -c \
    "UPDATE ir_config_parameter SET value = 'True', write_date = NOW()
       WHERE key = 'database.is_neutralized';
     INSERT INTO ir_config_parameter (key, value, create_uid, write_uid, create_date, write_date)
     SELECT 'database.is_neutralized', 'True', 1, 1, NOW(), NOW()
     WHERE NOT EXISTS (
       SELECT 1 FROM ir_config_parameter WHERE key = 'database.is_neutralized'
     );" >>"${LOG_FILE}" 2>&1
}

run_odoo_neutralize() {
  local dbname="$1"
  local addons_cli="/opt/soviez-erp/addons,/opt/soviez-erp/odoo/addons"
  local -a volume_args=(
    -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore"
    -v "${HOST_SOVIEZ_DIR}:/root/.soviez"
  )

  assert_safe_dbname "${dbname}"
  ensure_host_ledger_dir
  if [[ -n "${CUSTOM_ADDONS_HOST_PATH}" && -d "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    volume_args+=(-v "${CUSTOM_ADDONS_HOST_PATH}:${CUSTOM_ADDONS_CONTAINER_PATH}")
    addons_cli="${addons_cli},${CUSTOM_ADDONS_CONTAINER_PATH}"
  fi

  ui_wait "Running native neutralization on database ${dbname}..."
  # Prefer one-shot maintenance container (same pattern as --update); avoids -u odoo if absent.
  if docker run --rm \
      --network "${NETWORK_NAME}" \
      -e POSTGRES_USER="${DB_APP_USER}" \
      -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      "${volume_args[@]}" \
      "${APP_IMAGE}" \
      python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
        --addons-path="${addons_cli}" \
        --db_host="${DB_CONTAINER}" \
        --db_port=5432 \
        --db_user="${DB_APP_USER}" \
        --db_password="${SOVIEZ_DB_PASSWORD}" \
        --data-dir=/root/.local/share/Odoo \
        --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" \
        -d "${dbname}" --neutralize --stop-after-init >>"${LOG_FILE}" 2>&1; then
    ui_ok "Neutralize completed for ${dbname}"
    return 0
  fi

  # Fallback: exec into live web runner if present
  if container_running "${WEB_CONTAINER}"; then
    ui_warn "Maintenance neutralize failed — retrying via docker exec ${WEB_CONTAINER}..."
    if docker exec "${WEB_CONTAINER}" \
        python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
          --db_host="${DB_CONTAINER}" \
          --db_port=5432 \
          --db_user="${DB_APP_USER}" \
          --db_password="${SOVIEZ_DB_PASSWORD}" \
          --data-dir=/root/.local/share/Odoo \
          -d "${dbname}" --neutralize --stop-after-init >>"${LOG_FILE}" 2>&1; then
      ui_ok "Neutralize completed via ${WEB_CONTAINER}"
      return 0
    fi
  fi

  ui_error "Neutralize failed for ${dbname} — see ${LOG_FILE}"
  return 1
}

# ===========================================================================
# MODE: stage — clone live DB → stage + filestore, then neutralize
# ===========================================================================
mode_stage() {
  ensure_log_file
  require_cmd docker
  require_cmd python3

  if [[ -z "${STAGE_TENANT_REF}" || -z "${STAGE_SOURCE_DB}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --stage <tenant> <source_db>"
    ui_error "Example: sudo ./soviez.sh --stage soviez-web-1 production"
    exit 1
  fi

  assert_safe_dbname "${STAGE_SOURCE_DB}"
  assert_safe_dbname "${STAGE_DB_NAME}"

  if [[ "${STAGE_SOURCE_DB}" == "${STAGE_DB_NAME}" ]]; then
    ui_error "Source database cannot be named '${STAGE_DB_NAME}'"
    exit 1
  fi

  print_border_box "Soviez ERP — Staging Clone" \
    "Tenant: ${C_BOLD}${STAGE_TENANT_REF}${C_RESET}" \
    "Clone:  ${C_BOLD}${STAGE_SOURCE_DB}${C_RESET} → ${C_BOLD}${STAGE_DB_NAME}${C_RESET}" \
    "Then neutralize staging for safe testing."

  load_tenant_topology_from_ref "${STAGE_TENANT_REF}"

  if ! container_running "${DB_CONTAINER}"; then
    if container_exists "${DB_CONTAINER}"; then
      ui_wait "Starting database container ${DB_CONTAINER}..."
      docker start "${DB_CONTAINER}" >/dev/null
    else
      ui_error "Database container missing: ${DB_CONTAINER}"
      exit 1
    fi
  fi
  wait_for_postgres || exit 1

  if ! pg_database_exists "${STAGE_SOURCE_DB}"; then
    ui_error "Source database '${STAGE_SOURCE_DB}' does not exist on ${DB_CONTAINER}"
    exit 1
  fi

  # ---- Step A: terminate connections on source ----
  ui_wait "Terminating active connections to ${STAGE_SOURCE_DB}..."
  pg_terminate_db_connections "${STAGE_SOURCE_DB}"
  ui_ok "Connections terminated on ${STAGE_SOURCE_DB}"

  # If stage already exists, drop it cleanly first (idempotent re-stage)
  if pg_database_exists "${STAGE_DB_NAME}"; then
    ui_warn "Staging database '${STAGE_DB_NAME}' already exists — replacing it"
    pg_terminate_db_connections "${STAGE_DB_NAME}"
    ui_wait "Dropping existing ${STAGE_DB_NAME}..."
    docker exec "${DB_CONTAINER}" \
      psql -U "${DB_APP_USER}" -d postgres -v ON_ERROR_STOP=1 -c \
      "DROP DATABASE IF EXISTS \"${STAGE_DB_NAME}\";" >>"${LOG_FILE}" 2>&1
    ui_ok "Dropped previous ${STAGE_DB_NAME}"
  fi

  # ---- Step B: CREATE DATABASE stage WITH TEMPLATE ----
  ui_wait "Creating database ${STAGE_DB_NAME} WITH TEMPLATE ${STAGE_SOURCE_DB}..."
  if ! docker exec "${DB_CONTAINER}" \
      psql -U "${DB_APP_USER}" -d postgres -v ON_ERROR_STOP=1 -c \
      "CREATE DATABASE \"${STAGE_DB_NAME}\" WITH TEMPLATE \"${STAGE_SOURCE_DB}\" OWNER ${DB_APP_USER};" \
      >>"${LOG_FILE}" 2>&1; then
    ui_error "CREATE DATABASE failed — ensure no sessions remain on ${STAGE_SOURCE_DB}. See ${LOG_FILE}"
    exit 1
  fi
  ui_ok "Database ${STAGE_DB_NAME} cloned from ${STAGE_SOURCE_DB}"

  # ---- Step C: clone filestore ----
  if ! clone_filestore_dir "${STAGE_SOURCE_DB}" "${STAGE_DB_NAME}"; then
    ui_warn "DB exists but filestore clone failed — dropstage and retry if attachments are required"
    exit 1
  fi

  # ---- Step D: neutralize ----
  if ! run_odoo_neutralize "${STAGE_DB_NAME}"; then
    ui_warn "Native neutralize failed — applying SQL fail-safe only"
  fi
  ui_wait "Fail-safe: setting database.is_neutralized=True..."
  if mark_database_neutralized_sql "${STAGE_DB_NAME}"; then
    ui_ok "ir_config_parameter database.is_neutralized=True"
  else
    ui_error "Failed to set database.is_neutralized — see ${LOG_FILE}"
    exit 1
  fi

  print_green_success "Staging ready: ${STAGE_DB_NAME} (from ${STAGE_SOURCE_DB})"
  echo -e "  Tenant web: ${C_BOLD}${WEB_CONTAINER}${C_RESET}"
  echo -e "  Select database ${C_CYAN}${STAGE_DB_NAME}${C_RESET} in the Web Database Manager / dbfilter UI"
  echo -e "  Drop later: ${C_BOLD}sudo ./soviez.sh --dropstage ${STAGE_TENANT_REF} ${STAGE_DB_NAME}${C_RESET}"
  echo -e "  Log: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: dropstage — drop neutralized staging DB + filestore (safe shield)
# ===========================================================================
mode_dropstage() {
  ensure_log_file
  require_cmd docker
  local neut_val

  if [[ -z "${DROPSTAGE_TENANT_REF}" || -z "${DROPSTAGE_DB}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --dropstage <tenant> <db_to_drop>"
    ui_error "Example: sudo ./soviez.sh --dropstage soviez-web-1 stage"
    exit 1
  fi

  assert_safe_dbname "${DROPSTAGE_DB}"

  # Safety: never drop postgres system DB; warn if looks like a common production name without "stage"
  if [[ "${DROPSTAGE_DB}" == "postgres" ]]; then
    ui_error "Refusing to drop system database 'postgres'"
    exit 1
  fi

  print_border_box "Soviez ERP — Drop Staging Database" \
    "Tenant: ${C_BOLD}${DROPSTAGE_TENANT_REF}${C_RESET}" \
    "Drop:   ${C_BOLD}${DROPSTAGE_DB}${C_RESET} (Postgres + filestore)"

  load_tenant_topology_from_ref "${DROPSTAGE_TENANT_REF}"

  if ! container_running "${DB_CONTAINER}"; then
    if container_exists "${DB_CONTAINER}"; then
      docker start "${DB_CONTAINER}" >/dev/null
    else
      ui_error "Database container missing: ${DB_CONTAINER}"
      exit 1
    fi
  fi
  wait_for_postgres || exit 1

  # ---- Neutralization Safe Shield (refuse live production) ----
  if pg_database_exists "${DROPSTAGE_DB}"; then
    neut_val="$(pg_is_neutralized_value "${DROPSTAGE_DB}")"
    neut_val="$(printf '%s' "${neut_val}" | tr -d '[:space:]')"
    if [[ "${neut_val}" != "True" ]]; then
      echo -e "${C_RED}🚨 [ERROR] Safe Shield: The database '${DROPSTAGE_DB}' is NOT neutralized (Live Production!). Soviez will not drop production databases. Double-check your target database name.${C_RESET}" >&2
      log_file "ERROR dropstage blocked — database.is_neutralized='${neut_val}' for ${DROPSTAGE_DB}"
      exit 1
    fi
    ui_ok "Safe Shield: database.is_neutralized=True on ${DROPSTAGE_DB}"
  fi

  # ---- Step A: DROP DATABASE ----
  if pg_database_exists "${DROPSTAGE_DB}"; then
    ui_wait "Terminating connections to ${DROPSTAGE_DB}..."
    pg_terminate_db_connections "${DROPSTAGE_DB}"
    ui_ok "Connections cleared"
    ui_wait "Dropping database ${DROPSTAGE_DB}..."
    if ! docker exec "${DB_CONTAINER}" \
        psql -U "${DB_APP_USER}" -d postgres -v ON_ERROR_STOP=1 -c \
        "DROP DATABASE IF EXISTS \"${DROPSTAGE_DB}\";" >>"${LOG_FILE}" 2>&1; then
      ui_error "DROP DATABASE failed — see ${LOG_FILE}"
      exit 1
    fi
    ui_ok "Database ${DROPSTAGE_DB} dropped"
  else
    ui_warn "Database ${DROPSTAGE_DB} not found — skipping DROP"
  fi

  # ---- Step B: clean filestore ----
  remove_filestore_dir "${DROPSTAGE_DB}"

  print_green_success "Staging cleanup complete: ${DROPSTAGE_DB}"
  echo -e "  Log: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: backup — pg_dump + filestore archive with strict 5 GB host buffer
# ===========================================================================
mode_backup() {
  ensure_log_file

  if [[ -z "${BACKUP_TENANT_REF}" || -z "${BACKUP_DB}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --backup <tenant_index_or_web> <db_name>"
    ui_error "Example: sudo ./soviez.sh --backup 2 production"
    exit 1
  fi

  require_root --backup
  require_cmd docker
  require_cmd tar
  require_cmd df
  assert_safe_dbname "${BACKUP_DB}"

  print_border_box "Soviez ERP — Database Backup" \
    "Tenant: ${C_BOLD}${BACKUP_TENANT_REF}${C_RESET}" \
    "Database: ${C_BOLD}${BACKUP_DB}${C_RESET}" \
    "Guard: ${C_BOLD}5 GB host free-space buffer${C_RESET}"

  load_tenant_topology_from_ref "${BACKUP_TENANT_REF}"

  if ! container_running "${DB_CONTAINER}"; then
    if container_exists "${DB_CONTAINER}"; then
      ui_wait "Starting database container ${DB_CONTAINER}..."
      docker start "${DB_CONTAINER}" >/dev/null
    else
      ui_error "Database container missing: ${DB_CONTAINER}"
      exit 1
    fi
  fi
  wait_for_postgres || exit 1

  if ! pg_database_exists "${BACKUP_DB}"; then
    ui_error "Database '${BACKUP_DB}' does not exist on ${DB_CONTAINER}"
    exit 1
  fi

  mkdir -p "${BACKUP_ROOT}"
  chmod 700 "${BACKUP_ROOT}" 2>/dev/null || true

  local db_size filestore_size idx stamp archive workdir dump_file
  ui_wait "Measuring database and filestore size for space guard..."
  db_size="$(docker exec -i "${DB_CONTAINER}" \
    psql -U "${DB_APP_USER}" -d postgres -t -A -c \
    "SELECT pg_database_size('${BACKUP_DB}');" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -z "${db_size}" || ! "${db_size}" =~ ^[0-9]+$ ]]; then
    ui_error "Unable to measure database size for '${BACKUP_DB}'"
    exit 1
  fi
  filestore_size="$(measure_filestore_bytes "${BACKUP_DB}")"
  ui_info "DB size=$(bytes_to_gb_str "${db_size}") GB  filestore=$(bytes_to_gb_str "${filestore_size}") GB"

  assert_backup_disk_space "${db_size}" "${filestore_size}"

  idx="$(tenant_index_label)"
  stamp="$(date +%Y%m%d_%H%M%S)"
  archive="${BACKUP_ROOT}/soviez_backup_tenant${idx}_${BACKUP_DB}_${stamp}.tar.gz"
  workdir="$(mktemp -d /tmp/soviez_backup.XXXXXX)"
  dump_file="${workdir}/database.dump"
  mkdir -p "${workdir}/filestore"

  # Cleanup on failure
  trap 'rm -rf "${workdir}"' RETURN

  ui_wait "Running pg_dump -Fc for ${BACKUP_DB}..."
  if ! docker exec -i "${DB_CONTAINER}" \
      pg_dump -U "${DB_APP_USER}" -d "${BACKUP_DB}" -F c > "${dump_file}" 2>>"${LOG_FILE}"; then
    ui_error "pg_dump failed — see ${LOG_FILE}"
    exit 1
  fi
  if [[ ! -s "${dump_file}" ]]; then
    ui_error "pg_dump produced an empty archive"
    exit 1
  fi
  ui_ok "Database dump written ($(bytes_to_gb_str "$(wc -c < "${dump_file}")") GB)"

  ui_wait "Archiving filestore ${BACKUP_DB} from volume ${FILESTORE_VOLUME}..."
  if ! docker run --rm \
      -v "${FILESTORE_VOLUME}:/fs:ro" \
      -v "${workdir}/filestore:/out" \
      alpine:3.20 \
      sh -c "set -e
        if [ -d /fs/${BACKUP_DB} ]; then
          cp -a /fs/${BACKUP_DB}/. /out/
        else
          echo 'WARN: filestore directory missing — empty filestore in archive' >&2
        fi
      " >>"${LOG_FILE}" 2>&1; then
    ui_warn "Filestore copy had issues — continuing with dump-only contents (see ${LOG_FILE})"
  else
    ui_ok "Filestore staged for archive"
  fi

  printf '%s\n' \
    "tenant_index=${idx}" \
    "database=${BACKUP_DB}" \
    "web_container=${WEB_CONTAINER}" \
    "db_container=${DB_CONTAINER}" \
    "filestore_volume=${FILESTORE_VOLUME}" \
    "domain=${SOVIEZ_TENANT_DOMAIN:-}" \
    "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "${workdir}/MANIFEST.txt"

  ui_wait "Compressing archive → ${archive}..."
  if ! tar -czf "${archive}" -C "${workdir}" database.dump filestore MANIFEST.txt >>"${LOG_FILE}" 2>&1; then
    ui_error "tar failed — see ${LOG_FILE}"
    rm -f "${archive}" 2>/dev/null || true
    exit 1
  fi
  chmod 600 "${archive}" 2>/dev/null || true

  print_green_success "Backup complete"
  echo -e "  Archive: ${C_BOLD}${archive}${C_RESET}"
  echo -e "  Size:    ${C_CYAN}$(bytes_to_gb_str "$(wc -c < "${archive}")") GB${C_RESET}"
  echo -e "  List:    ${C_BOLD}sudo ./soviez.sh --backup-list${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: backup-list — inventory /var/soviez/backups (stdout table)
# ===========================================================================
mode_backup_list() {
  local path base idx db stamp domain show
  local -a files=()
  local found=0

  if [[ ! -d "${BACKUP_ROOT}" ]]; then
    echo ""
    echo -e "${C_BOLD}Soviez ERP — Backup Inventory${C_RESET}"
    echo -e "${C_DIM}No backup directory yet: ${BACKUP_ROOT}${C_RESET}"
    echo ""
    return 0
  fi

  shopt -s nullglob
  files=("${BACKUP_ROOT}"/soviez_backup_tenant*.tar.gz)
  shopt -u nullglob

  echo ""
  echo -e "${C_BOLD}Soviez ERP — Backup Inventory${C_RESET}"
  echo -e "${C_DIM}${BACKUP_ROOT}${C_RESET}"
  echo ""

  if (( ${#files[@]} == 0 )); then
    echo "No backup archives found matching soviez_backup_tenant*.tar.gz"
    echo ""
    return 0
  fi

  printf '+-----------------------------------------------+--------+------------------+----------------------------------+------------------+\n'
  printf '| %-45s | %-6s | %-16s | %-32s | %-16s |\n' \
    "File Name" "Tenant" "Target DB" "Domain" "Timestamp"
  printf '+-----------------------------------------------+--------+------------------+----------------------------------+------------------+\n'

  for path in "${files[@]}"; do
    [[ -f "${path}" ]] || continue
    base="$(basename "${path}")"
    if [[ "${base}" =~ ^soviez_backup_tenant([0-9]+)_(.+)_([0-9]{8}_[0-9]{6})\.tar\.gz$ ]]; then
      idx="${BASH_REMATCH[1]}"
      db="${BASH_REMATCH[2]}"
      stamp="${BASH_REMATCH[3]}"
    else
      idx="?"
      db="?"
      stamp="?"
    fi
    domain="$(lookup_domain_for_index "${idx}")"
    # Truncate long filenames for column width
    show="${base}"
    if (( ${#show} > 45 )); then
      show="${show:0:42}..."
    fi
    printf '| %-45s | %-6s | %-16s | %-32s | %-16s |\n' \
      "${show}" "${idx}" "${db}" "${domain}" "${stamp}"
    found=$((found + 1))
  done

  printf '+-----------------------------------------------+--------+------------------+----------------------------------+------------------+\n'
  echo -e "${C_DIM}${found} archive(s)${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: reset-pass — Odoo-compliant res.users password write via shell
# ===========================================================================
mode_reset_pass() {
  ensure_log_file

  if [[ -z "${RESET_TENANT_REF}" || -z "${RESET_DB}" || -z "${RESET_USERNAME}" || -z "${RESET_PASSWORD}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --reset-pass <tenant> <db_name> <username> <new_password>"
    ui_error "Example: sudo ./soviez.sh --reset-pass 1 production admin 'NewSecret!'"
    exit 1
  fi

  require_root --reset-pass
  require_cmd docker
  assert_safe_dbname "${RESET_DB}"

  print_border_box "Soviez ERP — Admin Password Reset" \
    "Tenant: ${C_BOLD}${RESET_TENANT_REF}${C_RESET}" \
    "Database: ${C_BOLD}${RESET_DB}${C_RESET}" \
    "User: ${C_BOLD}${RESET_USERNAME}${C_RESET}"

  load_tenant_topology_from_ref "${RESET_TENANT_REF}"

  if ! container_running "${WEB_CONTAINER}"; then
    if container_exists "${WEB_CONTAINER}"; then
      ui_wait "Starting web container ${WEB_CONTAINER}..."
      docker start "${WEB_CONTAINER}" >/dev/null
      sleep 3
    else
      ui_error "Web container missing: ${WEB_CONTAINER}"
      exit 1
    fi
  fi

  if ! container_running "${DB_CONTAINER}"; then
    if container_exists "${DB_CONTAINER}"; then
      docker start "${DB_CONTAINER}" >/dev/null
    else
      ui_error "Database container missing: ${DB_CONTAINER}"
      exit 1
    fi
  fi
  wait_for_postgres || exit 1

  if ! pg_database_exists "${RESET_DB}"; then
    ui_error "Database '${RESET_DB}' does not exist on ${DB_CONTAINER}"
    exit 1
  fi

  ui_wait "Updating password via soviez-bin shell (Odoo hashing)..."
  local py_script rc=0 login_b64 pass_b64
  login_b64="$(printf '%s' "${RESET_USERNAME}" | base64 | tr -d '\n')"
  pass_b64="$(printf '%s' "${RESET_PASSWORD}" | base64 | tr -d '\n')"
  py_script="$(cat <<'PY'
import base64
import os
import sys
login = base64.b64decode(os.environ.get("SOVIEZ_RESET_LOGIN_B64", "")).decode("utf-8")
passwd = base64.b64decode(os.environ.get("SOVIEZ_RESET_PASS_B64", "")).decode("utf-8")
if not login or not passwd:
    raise SystemExit("Missing login/password payload")
user = env["res.users"].search([("login", "=", login)], limit=1)
if not user:
    raise SystemExit(f"User not found: {login}")
user.write({"password": passwd})
env.cr.commit()
print(f"OK password updated for login={login} uid={user.id}")
PY
)"

  set +e
  # Prefer -u odoo when available; fall back to container default user.
  printf '%s\n' "${py_script}" | docker exec -i \
      -e "SOVIEZ_RESET_LOGIN_B64=${login_b64}" \
      -e "SOVIEZ_RESET_PASS_B64=${pass_b64}" \
      -u odoo \
      "${WEB_CONTAINER}" \
      python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
        --db_host="${DB_CONTAINER}" \
        --db_port=5432 \
        --db_user="${DB_APP_USER}" \
        --db_password="${SOVIEZ_DB_PASSWORD}" \
        --data-dir=/root/.local/share/Odoo \
        -d "${RESET_DB}" --stop-after-init shell >>"${LOG_FILE}" 2>&1
  rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "${py_script}" | docker exec -i \
        -e "SOVIEZ_RESET_LOGIN_B64=${login_b64}" \
        -e "SOVIEZ_RESET_PASS_B64=${pass_b64}" \
        "${WEB_CONTAINER}" \
        python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
          --db_host="${DB_CONTAINER}" \
          --db_port=5432 \
          --db_user="${DB_APP_USER}" \
          --db_password="${SOVIEZ_DB_PASSWORD}" \
          --data-dir=/root/.local/share/Odoo \
          -d "${RESET_DB}" --stop-after-init shell >>"${LOG_FILE}" 2>&1
    rc=$?
  fi
  set -e

  if (( rc != 0 )); then
    ui_error "Password reset failed — see ${LOG_FILE}"
    exit 1
  fi

  print_green_success "Password updated for ${RESET_USERNAME} on ${RESET_DB}"
  echo -e "  Log: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: change-domain — DNS verify + Nginx/SSL rebind for existing tenant
# ===========================================================================
mode_change_domain() {
  ensure_log_file

  if [[ -z "${CHANGE_DOMAIN_TENANT_REF}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --change-domain <tenant_index_or_web>"
    ui_error "Example: sudo ./soviez.sh --change-domain 2"
    exit 1
  fi

  require_root --change-domain
  require_cmd docker
  require_cmd nginx

  print_border_box "Soviez ERP — Change Tenant Domain" \
    "Tenant: ${C_BOLD}${CHANGE_DOMAIN_TENANT_REF}${C_RESET}"

  load_tenant_topology_from_ref "${CHANGE_DOMAIN_TENANT_REF}"

  local old_domain host_port new_domain public_ip
  old_domain="${SOVIEZ_TENANT_DOMAIN:-}"
  host_port="${SOVIEZ_HOST_PORT:-}"
  if [[ -z "${host_port}" ]]; then
    ui_error "Env sheet missing SOVIEZ_HOST_PORT — cannot rebind Nginx"
    exit 1
  fi

  echo -e "  Current domain: ${C_BOLD}${old_domain:-"(none)"}${C_RESET}"
  prompt_domain_confirmed
  new_domain="${TENANT_DOMAIN}"

  if [[ -n "${old_domain}" && "${old_domain}" == "${new_domain}" ]]; then
    ui_warn "New domain matches the current domain — nothing to change"
    exit 0
  fi

  public_ip="$(detect_public_ip)"
  PUBLIC_IP="${public_ip}"
  dns_validation_loop "${public_ip}" "${new_domain}"

  if [[ -n "${old_domain}" ]]; then
    ui_wait "Removing old Nginx site files for ${old_domain}..."
    remove_nginx_site_for_domain "${old_domain}"
    ui_ok "Old Nginx bindings removed"
  fi

  ui_wait "Updating SOVIEZ_TENANT_DOMAIN in ${ENV_FILE}..."
  persist_env_key "SOVIEZ_TENANT_DOMAIN" "${new_domain}"
  SOVIEZ_TENANT_DOMAIN="${new_domain}"
  TENANT_DOMAIN="${new_domain}"
  ui_ok "Env sheet updated → ${new_domain}"

  if ! provision_tenant_https "${new_domain}" "${host_port}"; then
    ui_error "HTTPS provision failed for ${new_domain} — see ${LOG_FILE}"
    exit 1
  fi

  verify_and_heal_tenant_https "${new_domain}" "${host_port}" || true
  print_ssl_status_report "${new_domain}"

  print_green_success "Domain changed to ${new_domain}"
  echo -e "  Previous: ${C_DIM}${old_domain:-"(none)"}${C_RESET}"
  echo -e "  Env:      ${C_BOLD}${ENV_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: monitor — docker stats for running soviez-* containers
# ===========================================================================
mode_monitor() {
  require_cmd docker
  local -a names=()
  local n

  while IFS= read -r n; do
    [[ -n "${n}" ]] || continue
    names+=("${n}")
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^soviez-' || true)

  if (( ${#names[@]} == 0 )); then
    echo ""
    echo -e "${C_BOLD}Soviez ERP — Live Monitor${C_RESET}"
    echo "No running containers whose names start with soviez-."
    echo ""
    return 0
  fi

  echo ""
  echo -e "${C_BOLD}Soviez ERP — Live Monitor${C_RESET}"
  echo -e "${C_DIM}Tracking ${#names[@]} running container(s)${C_RESET}"
  echo ""
  docker stats "${names[@]}"
}

# ===========================================================================
# MODE: logs — follow tenant web container logs
# ===========================================================================
mode_logs() {
  if [[ -z "${LOGS_TENANT_REF}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --logs <tenant_index_or_web>"
    ui_error "Example: sudo ./soviez.sh --logs soviez-web-1"
    exit 1
  fi

  require_cmd docker

  load_tenant_topology_from_ref "${LOGS_TENANT_REF}"

  if ! container_exists "${WEB_CONTAINER}"; then
    ui_error "Web container not found: ${WEB_CONTAINER}"
    exit 1
  fi

  echo ""
  echo -e "${C_BOLD}Soviez ERP — Logs${C_RESET}  ${C_DIM}${WEB_CONTAINER} (tail 100, follow)${C_RESET}"
  echo ""
  exec docker logs -f --tail 100 "${WEB_CONTAINER}"
}

# ===========================================================================
# MODE: list — administrative tenant dashboard (stdout only, no log writes)
# ===========================================================================
docker_web_status_label() {
  local container="$1"
  local status_raw=""

  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "⚪ Docker N/A"
    return 0
  fi

  status_raw="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null || true)"
  case "${status_raw}" in
    running)
      printf '%s\n' "🟢 Running"
      ;;
    "")
      printf '%s\n' "⚪ Not Found"
      ;;
    *)
      # exited, created, restarting, dead, paused, …
      printf '%s\n' "🔴 Stopped"
      ;;
  esac
}

list_tenants() {
  local path base idx domain web_container status_label real
  local -a env_paths=()
  local -a seen_reals=()
  local -a rows_idx=()
  local -a rows_web=()
  local -a rows_dom=()
  local -a rows_st=()
  local i skip prev count=0

  # Prefer /root (canonical appliance root), then INSTANCE_ROOT / cwd.
  shopt -s nullglob
  for path in \
      /root/.soviez_*.env \
      "${INSTANCE_ROOT}"/.soviez_*.env \
      "$(pwd)"/.soviez_*.env; do
    [[ -f "${path}" ]] || continue
    base="$(basename "${path}")"
    [[ "${base}" =~ ^\.soviez_([0-9]+)\.env$ ]] || continue

    real="$(readlink -f "${path}" 2>/dev/null || echo "${path}")"
    skip=0
    for prev in "${seen_reals[@]:-}"; do
      if [[ "${prev}" == "${real}" ]]; then
        skip=1
        break
      fi
    done
    (( skip == 1 )) && continue
    seen_reals+=("${real}")
    env_paths+=("${path}")
  done
  shopt -u nullglob

  if ((${#env_paths[@]} == 0)); then
    echo ""
    echo "No Soviez tenant environment sheets found."
    echo "  Looked in: /root  ${INSTANCE_ROOT}  $(pwd)"
    echo "  Provision with: sudo ./soviez.sh --new"
    echo ""
    return 0
  fi

  # Sort by numeric index ascending
  local sorted=""
  sorted="$(
    for path in "${env_paths[@]}"; do
      base="$(basename "${path}")"
      [[ "${base}" =~ ^\.soviez_([0-9]+)\.env$ ]] || continue
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${path}"
    done | sort -n -k1,1
  )"

  while IFS=$'\t' read -r idx path; do
    [[ -n "${idx}" && -n "${path}" ]] || continue

    # Safe read — never `source` (malformed sheets must not crash the dashboard).
    domain="$(grep -E '^SOVIEZ_TENANT_DOMAIN=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    domain="${domain//$'\r'/}"
    domain="${domain%\"}"
    domain="${domain#\"}"
    domain="${domain%\'}"
    domain="${domain#\'}"
    if [[ -z "${domain}" ]]; then
      domain="[Malformed / No Domain]"
    fi

    web_container="$(grep -E '^SOVIEZ_WEB_CONTAINER=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    web_container="${web_container//$'\r'/}"
    if [[ -z "${web_container}" ]]; then
      web_container="soviez-web-${idx}"
    fi

    status_label="$(docker_web_status_label "${web_container}")"

    rows_idx+=("${idx}")
    rows_web+=("${web_container}")
    rows_dom+=("${domain}")
    rows_st+=("${status_label}")
    count=$((count + 1))
  done <<< "${sorted}"

  echo ""
  echo -e "${C_BOLD}Soviez ERP — Tenant Inventory${C_RESET}"
  echo -e "${C_DIM}${count} tenant sheet(s) discovered${C_RESET}"
  echo ""
  printf '+-------+----------------------+----------------------------------+-------------------+\n'
  printf '| %-5s | %-20s | %-32s | %-17s |\n' \
    "Index" "Web Container" "Linked Domain" "Docker Status"
  printf '+-------+----------------------+----------------------------------+-------------------+\n'
  for (( i = 0; i < count; i++ )); do
    printf '| %-5s | %-20s | %-32s | %-17s |\n' \
      "${rows_idx[$i]}" \
      "${rows_web[$i]}" \
      "${rows_dom[$i]}" \
      "${rows_st[$i]}"
  done
  printf '+-------+----------------------+----------------------------------+-------------------+\n'
  echo ""
}

# ===========================================================================
# Dispatch
# ===========================================================================
case "${MODE}" in
  list|backup-list|monitor|logs)
    ;;
  *)
    ensure_log_file
    ;;
esac

case "${MODE}" in
  init)
    mode_init
    ;;
  new)
    mode_new
    ;;
  list)
    list_tenants
    ;;
  backup)
    mode_backup
    ;;
  backup-list)
    mode_backup_list
    ;;
  formsetup)
    mode_formsetup
    ;;
  formssl)
    mode_formssl
    ;;
  stage)
    mode_stage
    ;;
  dropstage)
    mode_dropstage
    ;;
  reset-pass)
    mode_reset_pass
    ;;
  change-domain)
    mode_change_domain
    ;;
  monitor)
    mode_monitor
    ;;
  logs)
    mode_logs
    ;;
  update)
    mode_update
    ;;
  recover)
    mode_recover
    ;;
  formworkers)
    mode_formworkers
    ;;
  *)
    ui_error "Unknown mode: ${MODE}"
    exit 1
    ;;
esac
