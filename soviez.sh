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
#   ./soviez.sh --purge <tenant>         Irreversibly destroy a tenant (containers, volumes, configs)
#   ./soviez.sh --rebuild <tenant>       Wipe DB + filestore; keep domain, env, and custom addons
#   ./soviez.sh --recoverdbpass        Rotate internal admin_passwd (stored in env sheet)
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
readonly DEFAULT_APP_DB_NAME="production"
readonly DEFAULT_APP_LOGIN="admin"
readonly APP_PASSWORD_LEN=12
readonly DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
readonly DOCKER_PRUNE_CRON="/etc/cron.weekly/soviez-docker-prune"
readonly FAIL2BAN_JAIL_LOCAL="/etc/fail2ban/jail.local"
readonly CERTBOT_NGINX_RELOAD_HOOK="/etc/letsencrypt/renewal-hooks/post/nginx-reload.sh"
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
PURGE_TENANT_REF=""
REBUILD_TENANT_REF=""
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
    --purge)
      MODE="purge"
      ;;
    --rebuild)
      MODE="rebuild"
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
  ./soviez.sh --purge <tenant>               Irreversibly destroy tenant (containers, volumes, configs)
  ./soviez.sh --rebuild <tenant>             Wipe DB + filestore; keep domain, env, custom addons
  ./soviez.sh --recoverdbpass                Rotate internal admin_passwd (env sheet)
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
  sudo ./soviez.sh --rebuild soviez-web-1
  sudo ./soviez.sh --purge soviez-web-1

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
      elif [[ "${MODE}" == "purge" && -z "${PURGE_TENANT_REF}" ]]; then
        PURGE_TENANT_REF="${clean_arg}"
      elif [[ "${MODE}" == "rebuild" && -z "${REBUILD_TENANT_REF}" ]]; then
        REBUILD_TENANT_REF="${clean_arg}"
      else
        echo "[ERROR] Unknown argument: ${arg}" >&2
        echo "[ERROR] Try: ./soviez.sh --help" >&2
        exit 1
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Self-preservation & auto-update
# When piped (curl|bash) the wizard never lands on disk — operators then hit
# "command not found" for sudo ./soviez.sh --new. Persist (and refresh) ./soviez.sh
# for piped runs and every --init so the next step always works.
# ---------------------------------------------------------------------------
readonly SOVIEZ_SH_PUBLIC_URL="https://soviez.sh"
readonly SOVIEZ_SH_LOCAL_PATH="./soviez.sh"

is_piped_execution() {
  local zero="${0:-}"
  local base
  base="$(basename -- "${zero}" 2>/dev/null || printf '%s\n' "${zero}")"

  # curl -sSL … | bash  →  $0 is the interpreter name
  case "${base}" in
    bash|sh|dash|zsh|-bash|-sh) return 0 ;;
  esac

  # Process substitution / FIFO feeds (e.g. bash <(curl …))
  case "${zero}" in
    /dev/fd/*|/proc/self/fd/*) return 0 ;;
  esac

  # $0 is not a real on-disk script path
  if [[ ! -f "${zero}" ]]; then
    return 0
  fi

  return 1
}

ensure_local_soviez_sh() {
  # Best-effort: never abort the rest of the wizard if the download fails.
  if ! command -v curl >/dev/null 2>&1; then
    echo -e "${C_YELLOW}[WARN]${C_RESET} curl not found — could not save ${SOVIEZ_SH_LOCAL_PATH} locally." >&2
    return 0
  fi

  if curl -fsSL "${SOVIEZ_SH_PUBLIC_URL}" -o "${SOVIEZ_SH_LOCAL_PATH}"; then
    chmod +x "${SOVIEZ_SH_LOCAL_PATH}" || true
    echo -e "${C_GREEN}[OK]${C_RESET}   ${C_CYAN}Soviez ERP wizard saved locally as ${C_BOLD}./soviez.sh${C_RESET}"
  else
    echo -e "${C_YELLOW}[WARN]${C_RESET} Failed to download installer to ./soviez.sh — continuing." >&2
  fi
}

if is_piped_execution || [[ "${MODE}" == "init" ]]; then
  ensure_local_soviez_sh
fi

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

# 64-char hex secret for license migration HMAC (SOVIEZ_MIGRATION_SECRET).
generate_migration_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
}

# Ensure the tenant env sheet has SOVIEZ_MIGRATION_SECRET and export it.
# Generates a strong random value once; never overwrites an existing secret.
ensure_migration_secret() {
  if [[ -z "${SOVIEZ_MIGRATION_SECRET:-}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    SOVIEZ_MIGRATION_SECRET="$(
      grep -E '^SOVIEZ_MIGRATION_SECRET=' "${ENV_FILE}" 2>/dev/null \
        | head -1 | cut -d= -f2- || true
    )"
  fi
  if [[ -z "${SOVIEZ_MIGRATION_SECRET:-}" ]]; then
    SOVIEZ_MIGRATION_SECRET="$(generate_migration_secret)"
    if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
      persist_env_key "SOVIEZ_MIGRATION_SECRET" "${SOVIEZ_MIGRATION_SECRET}"
    fi
  fi
  if [[ -z "${SOVIEZ_MIGRATION_SECRET:-}" ]]; then
    ui_error "Failed to generate SOVIEZ_MIGRATION_SECRET."
    return 1
  fi
  export SOVIEZ_MIGRATION_SECRET
}

# 12-character alphanumeric ERP login password (Day-1 admin user).
generate_app_password() {
  python3 - <<PY
import secrets
import string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(${APP_PASSWORD_LEN})))
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

# Detect the NUL-squash bug: CMD became "postgres-cshared_buffers=…" (single token).
postgres_cmd_is_mangled() {
  container_exists "${DB_CONTAINER}" || return 1
  local cmd
  cmd="$(docker inspect -f '{{join .Config.Cmd " "}}' "${DB_CONTAINER}" 2>/dev/null || true)"
  [[ -z "${cmd}" ]] && return 1
  if [[ "${cmd}" == *postgres-c* ]] \
    || [[ "${cmd}" == *"-cshared_buffers"* ]] \
    || [[ "${cmd}" == *"-ceffective_cache"* ]]; then
    return 0
  fi
  return 1
}

postgres_engine_state() {
  docker inspect -f '{{.State.Status}}' "${DB_CONTAINER}" 2>/dev/null || printf '%s\n' "missing"
}

# Soft-delete DB container only (named volume soviez_db_data_N is preserved).
recycle_postgres_engine() {
  local reason="${1:-unhealthy PostgreSQL engine}"
  ui_warn "${reason} — recreating ${DB_CONTAINER} (data volume ${DB_VOLUME} preserved)..."
  docker stop "${DB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
  docker rm -f "${DB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
  _docker_run_postgres_container || return 1
  wait_for_postgres || return 1
  ui_ok "PostgreSQL recreated (${DB_CONTAINER})"
  return 0
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

# Tenant runtime config (100% Soviez-branded filenames — zero "odoo" in conf paths):
#   Host:      /var/soviez/volumes/soviez-web-N/conf/tenant.soviez.conf  ← tuned by --formworkers
#   Container: bind-mounted RO as /opt/soviez-erp/tenant.soviez.conf
#   Image:     /opt/soviez-erp/soviez.conf (lab/CMD default; separate from per-tenant file)
tenant_soviez_conf_path() {
  printf '%s/%s/conf/tenant.soviez.conf\n' "${SOVIEZ_VOLUME_ROOT}" "${WEB_CONTAINER}"
}

# Legacy path from pre-rebrand installs (migrate once, then unused).
tenant_legacy_odoo_conf_path() {
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

ensure_tenant_soviez_conf() {
  local conf_path dir
  conf_path="$(tenant_soviez_conf_path)"
  dir="$(dirname "${conf_path}")"
  mkdir -p "${dir}"
  chmod 755 "${SOVIEZ_VOLUME_ROOT}" "${SOVIEZ_VOLUME_ROOT}/${WEB_CONTAINER}" "${dir}" 2>/dev/null || true

  # One-time migration from pre-rebrand host filename.
  local legacy_path
  legacy_path="$(tenant_legacy_odoo_conf_path)"
  if [[ ! -f "${conf_path}" && -f "${legacy_path}" ]]; then
    mv "${legacy_path}" "${conf_path}"
    log_file "Migrated legacy conf ${legacy_path} → ${conf_path}"
    ui_ok "Migrated tenant config to tenant.soviez.conf"
  fi

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
    log_file "Created tenant runtime tenant.soviez.conf at ${conf_path}"
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

# Resolve host tenant conf for a web container name (branded path, else legacy).
tenant_conf_path_for_web() {
  local web="$1"
  local branded legacy
  branded="${SOVIEZ_VOLUME_ROOT}/${web}/conf/tenant.soviez.conf"
  legacy="${SOVIEZ_VOLUME_ROOT}/${web}/conf/odoo.conf"
  if [[ -f "${branded}" ]]; then
    printf '%s\n' "${branded}"
  elif [[ -f "${legacy}" ]]; then
    printf '%s\n' "${legacy}"
  else
    printf '%s\n' "${branded}"
  fi
}

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
      local conf_file
      conf_file="$(tenant_conf_path_for_web "${web}")"
      workers="$(conf_get_option "${conf_file}" workers || true)"
      hard="$(conf_get_option "${conf_file}" limit_memory_hard || true)"
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
        local conf_file_cpu
        conf_file_cpu="$(tenant_conf_path_for_web "${web}")"
        workers="$(conf_get_option "${conf_file_cpu}" workers || true)"
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

# /dev/shm must fit PostgreSQL shared_buffers (Docker default 64m is too small when tuned).
postgres_shm_size() {
  local shared_mb="${SOVIEZ_PG_SHARED_BUFFERS_MB:-${PG_SHARED_MB:-0}}"
  if [[ "${shared_mb}" =~ ^[0-9]+$ ]] && (( shared_mb > 0 )); then
    printf '%sm\n' "$(( shared_mb + 64 ))"
  else
    printf '%s\n' "64m"
  fi
}

# Low-level docker run for the Postgres engine (single source of truth).
# CMD args are separate words — NEVER serialize via $(…) with NULs (bash strips
# \\0 and concatenates into "postgres-cshared_buffers=…", the Safe Restart crash).
_docker_run_postgres_container() {
  local shared_mb="${SOVIEZ_PG_SHARED_BUFFERS_MB:-${PG_SHARED_MB:-}}"
  local effective_mb="${SOVIEZ_PG_EFFECTIVE_CACHE_MB:-${PG_EFFECTIVE_MB:-}}"
  local shm_size
  local run_rc=0
  shm_size="$(postgres_shm_size)"

  set +e
  if [[ -n "${shared_mb}" ]]; then
    docker run -d \
      --name "${DB_CONTAINER}" \
      --restart unless-stopped \
      --network "${NETWORK_NAME}" \
      --shm-size="${shm_size}" \
      -e POSTGRES_DB=postgres \
      -e POSTGRES_USER=soviez \
      -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -v "${DB_VOLUME}:/var/lib/postgresql/data" \
      "${DB_IMAGE}" \
      postgres \
      -c "shared_buffers=${shared_mb}MB" \
      -c "effective_cache_size=${effective_mb}MB" \
      -c "maintenance_work_mem=64MB" \
      -c "work_mem=16MB" >>"${LOG_FILE}" 2>&1
    run_rc=$?
  else
    docker run -d \
      --name "${DB_CONTAINER}" \
      --restart unless-stopped \
      --network "${NETWORK_NAME}" \
      --shm-size="${shm_size}" \
      -e POSTGRES_DB=postgres \
      -e POSTGRES_USER=soviez \
      -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -v "${DB_VOLUME}:/var/lib/postgresql/data" \
      "${DB_IMAGE}" >>"${LOG_FILE}" 2>&1
    run_rc=$?
  fi
  set -e

  if (( run_rc != 0 )); then
    ui_error "Failed to start ${DB_CONTAINER} (docker run exit ${run_rc}) — see ${LOG_FILE}"
    return "${run_rc}"
  fi
  return 0
}


# Canonical DB bring-up used by --new / --formsetup / --rebuild / Safe Restart.
start_db_container() {
  if container_exists "${DB_CONTAINER}"; then
    if postgres_cmd_is_mangled; then
      recycle_postgres_engine "Broken PostgreSQL launch command on ${DB_CONTAINER}" || return 1
      return 0
    fi
    local st
    st="$(postgres_engine_state)"
    case "${st}" in
      restarting|dead|exited|created)
        recycle_postgres_engine "PostgreSQL ${DB_CONTAINER} state=${st}" || return 1
        return 0
        ;;
    esac
    if container_running "${DB_CONTAINER}"; then
      log_file "DB ${DB_CONTAINER} already running"
      if wait_for_postgres; then
        ui_ok "PostgreSQL ready (${DB_CONTAINER})"
        return 0
      fi
      recycle_postgres_engine "PostgreSQL ${DB_CONTAINER} is up but not accepting connections" || return 1
      return 0
    fi
    docker start "${DB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
    if wait_for_postgres; then
      ui_ok "PostgreSQL started (${DB_CONTAINER})"
      return 0
    fi
    recycle_postgres_engine "PostgreSQL ${DB_CONTAINER} failed to become ready after start" || return 1
    return 0
  fi

  ui_wait "Creating PostgreSQL (${DB_CONTAINER})..."
  _docker_run_postgres_container || return 1
  wait_for_postgres || return 1
  ui_ok "PostgreSQL created (${DB_CONTAINER}, shm-size=$(postgres_shm_size))"
}

# Back-compat aliases
run_postgres_container() { _docker_run_postgres_container "$@"; }
ensure_postgres_container() { start_db_container "$@"; }
resume_postgres_container() { start_db_container "$@"; }

recreate_postgres_with_tuning() {
  ui_wait "Recreating ${DB_CONTAINER} on volume ${DB_VOLUME} with tuned PostgreSQL buffers..."
  _docker_run_postgres_container || return 1
  wait_for_postgres || return 1
  ui_ok "PostgreSQL ${DB_CONTAINER} online with tuned buffers (shm-size=$(postgres_shm_size))"
}

apply_tenant_resource_tuning() {
  ensure_tenant_soviez_conf
  local conf_path
  conf_path="$(tenant_soviez_conf_path)"

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

  recreate_postgres_with_tuning || return 1

  conf_set_option "${conf_path}" workers "${WORKERS}"
  conf_set_option "${conf_path}" limit_memory_soft "${LIMIT_SOFT_BYTES}"
  conf_set_option "${conf_path}" limit_memory_hard "${LIMIT_HARD_BYTES}"

  ui_wait "Applying Docker cgroup limits on ${WEB_CONTAINER}..."
  docker update \
    --cpus="${DOCKER_CPUS}" \
    --memory="${DOCKER_MEM_MB}m" \
    --memory-swap="${DOCKER_MEM_MB}m" \
    "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1

  ui_wait "Starting ${WEB_CONTAINER} with updated tenant.soviez.conf..."
  docker start "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1

  ui_ok "Resource tuning complete for ${WEB_CONTAINER}"
  echo -e "  ${C_DIM}Config:${C_RESET} ${conf_path}"
  echo -e "  ${C_DIM}Workers:${C_RESET} ${WORKERS}  ${C_DIM}Soft/Hard:${C_RESET} $(( LIMIT_SOFT_BYTES / 1024 / 1024 ))MB / $(( LIMIT_HARD_BYTES / 1024 / 1024 ))MB"
  echo -e "  ${C_DIM}PostgreSQL:${C_RESET} shared_buffers=${PG_SHARED_MB}MB  effective_cache_size=${PG_EFFECTIVE_MB}MB  shm-size=$(postgres_shm_size)"
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

  mkdir -p "${SOVIEZ_HOST_ROOT}"
  mkdir -p "$(dirname "${CUSTOM_ADDONS_HOST_PATH}")"
  mkdir -p "${CUSTOM_ADDONS_HOST_PATH}"

  chmod 755 "${SOVIEZ_HOST_ROOT}" \
    "$(dirname "${CUSTOM_ADDONS_HOST_PATH}")" \
    "${CUSTOM_ADDONS_HOST_PATH}"

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    chown "${SUDO_USER}:${SUDO_USER}" \
      "$(dirname "${CUSTOM_ADDONS_HOST_PATH}")" \
      "${CUSTOM_ADDONS_HOST_PATH}" 2>/dev/null || true
  fi

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

# Low-level docker run for the web/ERP container (single source of truth).
_docker_run_web_container() {
  local addons_cli runtime_conf
  local -a volume_args=() docker_limits=()
  local run_rc=0

  ensure_host_ledger_dir
  ensure_custom_addons_dir
  ensure_tenant_soviez_conf
  runtime_conf="$(tenant_soviez_conf_path)"

  volume_args+=(
    -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore"
    -v "${HOST_SOVIEZ_DIR}:/root/.soviez"
    -v "${runtime_conf}:/opt/soviez-erp/tenant.soviez.conf:ro"
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

  ensure_migration_secret || return 1

  set +e
  docker run -d \
    --name "${WEB_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    --mac-address "${SOVIEZ_CONTAINER_MAC}" \
    -p "${SOVIEZ_HOST_PORT}:8069" \
    -e POSTGRES_USER=soviez \
    -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e SOVIEZ_MIGRATION_SECRET="${SOVIEZ_MIGRATION_SECRET}" \
    "${docker_limits[@]}" \
    "${volume_args[@]}" \
    "${APP_IMAGE}" \
    python3 soviez-bin -c /opt/soviez-erp/tenant.soviez.conf \
      --addons-path="${addons_cli}" \
      --db_host="${DB_CONTAINER}" \
      --db_port=5432 \
      --db_user=soviez \
      --db_password="${SOVIEZ_DB_PASSWORD}" \
      --data-dir=/root/.local/share/Odoo \
      --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" >>"${LOG_FILE}" 2>&1
  run_rc=$?
  set -e

  if (( run_rc != 0 )); then
    ui_error "Failed to start ${WEB_CONTAINER} (docker run exit ${run_rc}) — see ${LOG_FILE}"
    return "${run_rc}"
  fi
  return 0
}

# True when the web container is missing SOVIEZ_MIGRATION_SECRET in its env.
web_missing_migration_secret() {
  local val
  container_exists "${WEB_CONTAINER}" || return 0
  val="$(
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${WEB_CONTAINER}" 2>/dev/null \
      | grep -E '^SOVIEZ_MIGRATION_SECRET=' | head -1 || true
  )"
  [[ -z "${val#SOVIEZ_MIGRATION_SECRET=}" ]]
}

# Canonical web bring-up used by --new / --formsetup / --rebuild / --update.
# Pass 1 to force recreate even if a container already exists.
start_web_container() {
  local force="${1:-0}"

  ensure_host_ledger_dir
  ensure_custom_addons_dir
  ensure_tenant_soviez_conf
  ensure_migration_secret || return 1

  if (( force == 1 )) && container_exists "${WEB_CONTAINER}"; then
    docker rm -f "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
  fi

  if container_running "${WEB_CONTAINER}"; then
    if web_needs_addons_remount || web_missing_migration_secret; then
      ui_wait "Recycling ${WEB_CONTAINER} to refresh mounts/env (migration secret / addons)..."
      docker rm -f "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
      _docker_run_web_container || return 1
      ui_ok "Web ERP recreated (${WEB_CONTAINER})"
      return 0
    fi
    ui_ok "Web ERP already running (${WEB_CONTAINER})"
    return 0
  fi

  if container_exists "${WEB_CONTAINER}"; then
    if web_needs_addons_remount || web_missing_migration_secret; then
      ui_wait "Recycling stopped ${WEB_CONTAINER} to refresh mounts/env (migration secret / addons)..."
      docker rm -f "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
      _docker_run_web_container || return 1
      ui_ok "Web ERP recreated (${WEB_CONTAINER})"
      return 0
    fi
    ui_wait "Starting stopped web ERP (${WEB_CONTAINER})..."
    if docker start "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1; then
      ui_ok "Web ERP started (${WEB_CONTAINER})"
      return 0
    fi
    ui_warn "docker start failed for ${WEB_CONTAINER} — recreating..."
    docker rm -f "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
  fi

  ui_wait "Creating web ERP (${WEB_CONTAINER})..."
  _docker_run_web_container || return 1
  ui_ok "Web ERP created (${WEB_CONTAINER})"
}

launch_web_container() { start_web_container 1; }
resume_web_container() { start_web_container 0; }

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

  ensure_migration_secret || return 1

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
      -e SOVIEZ_MIGRATION_SECRET="${SOVIEZ_MIGRATION_SECRET}" \
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
  ensure_migration_secret || exit 1
}

# ---------------------------------------------------------------------------
# Application database bootstrap (auto-provision for --new / --rebuild)
# ---------------------------------------------------------------------------

addons_cli_for_runtime() {
  local addons_cli="/opt/soviez-erp/addons,/opt/soviez-erp/odoo/addons"
  if [[ -n "${CUSTOM_ADDONS_HOST_PATH:-}" && -d "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    addons_cli="${addons_cli},${CUSTOM_ADDONS_CONTAINER_PATH}"
  fi
  printf '%s\n' "${addons_cli}"
}

# Volume mounts shared by one-shot maintenance containers (provision / password / upgrades).
# No --mac-address here — that belongs only on the long-running web container.
odoo_maintenance_volume_args() {
  local -n _out="$1"
  local runtime_conf
  _out=(
    -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore"
    -v "${HOST_SOVIEZ_DIR}:/root/.soviez"
  )
  ensure_host_ledger_dir
  ensure_custom_addons_dir
  ensure_tenant_soviez_conf
  runtime_conf="$(tenant_soviez_conf_path)"
  if [[ -f "${runtime_conf}" ]]; then
    _out+=(-v "${runtime_conf}:/opt/soviez-erp/tenant.soviez.conf:ro")
  fi
  if [[ -n "${CUSTOM_ADDONS_HOST_PATH:-}" && -d "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    _out+=(-v "${CUSTOM_ADDONS_HOST_PATH}:${CUSTOM_ADDONS_CONTAINER_PATH}")
  fi
}

# Stop the live web ERP so a maintenance one-shot can own filestore/DB locks.
# Never run -i / shell --stop-after-init via docker exec against a live Odoo PID.
stop_web_for_maintenance() {
  if container_running "${WEB_CONTAINER}"; then
    ui_wait "Stopping ${WEB_CONTAINER} for database maintenance..."
    docker stop "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
  fi
}

# Config path inside maintenance one-shots (tenant bind if present, else image default).
odoo_maintenance_conf_path() {
  local runtime_conf
  runtime_conf="$(tenant_soviez_conf_path)"
  if [[ -f "${runtime_conf}" ]]; then
    printf '%s\n' "/opt/soviez-erp/tenant.soviez.conf"
  else
    printf '%s\n' "/opt/soviez-erp/soviez.conf"
  fi
}

# One-shot Odoo job on the tenant network (no MAC — never clashes with soviez-web-N).
# Extra args are appended after the common soviez-bin connection flags.
# Usage: run_odoo_maintenance -- -d production -i base,... --without-demo=all --stop-after-init
#    or: printf script | run_odoo_maintenance_stdin -d production --stop-after-init
run_odoo_maintenance() {
  local addons_cli conf_path
  local -a volume_args=()
  local rc=0

  wait_for_postgres || return 1
  stop_web_for_maintenance
  odoo_maintenance_volume_args volume_args
  addons_cli="$(addons_cli_for_runtime)"
  conf_path="$(odoo_maintenance_conf_path)"
  ensure_migration_secret || return 1

  set +e
  docker run --rm \
    --network "${NETWORK_NAME}" \
    -e POSTGRES_USER=soviez \
    -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e SOVIEZ_MIGRATION_SECRET="${SOVIEZ_MIGRATION_SECRET}" \
    "${volume_args[@]}" \
    "${APP_IMAGE}" \
    python3 soviez-bin -c "${conf_path}" \
      --addons-path="${addons_cli}" \
      --db_host="${DB_CONTAINER}" \
      --db_port=5432 \
      --db_user=soviez \
      --db_password="${SOVIEZ_DB_PASSWORD}" \
      --data-dir=/root/.local/share/Odoo \
      --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" \
      "$@" >>"${LOG_FILE}" 2>&1
  rc=$?
  set -e
  return "${rc}"
}

# Same as run_odoo_maintenance but runs the `shell` subcommand (stdin scripts).
# CLI must be: soviez-bin shell [options] — NOT options then trailing "shell".
run_odoo_maintenance_stdin() {
  local addons_cli conf_path
  local -a volume_args=()
  local rc=0

  wait_for_postgres || return 1
  stop_web_for_maintenance
  odoo_maintenance_volume_args volume_args
  addons_cli="$(addons_cli_for_runtime)"
  conf_path="$(odoo_maintenance_conf_path)"
  ensure_migration_secret || return 1

  set +e
  docker run --rm -i \
    --network "${NETWORK_NAME}" \
    -e POSTGRES_USER=soviez \
    -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e SOVIEZ_MIGRATION_SECRET="${SOVIEZ_MIGRATION_SECRET}" \
    -e "SOVIEZ_RESET_LOGIN_B64=${SOVIEZ_RESET_LOGIN_B64:-}" \
    -e "SOVIEZ_RESET_PASS_B64=${SOVIEZ_RESET_PASS_B64:-}" \
    "${volume_args[@]}" \
    "${APP_IMAGE}" \
    python3 soviez-bin shell -c "${conf_path}" \
      --addons-path="${addons_cli}" \
      --db_host="${DB_CONTAINER}" \
      --db_port=5432 \
      --db_user=soviez \
      --db_password="${SOVIEZ_DB_PASSWORD}" \
      --data-dir=/root/.local/share/Odoo \
      --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" \
      "$@" >>"${LOG_FILE}" 2>&1
  rc=$?
  set -e
  return "${rc}"
}

# Write Odoo login password via shell (correct hashing — never raw SQL).
# Uses a one-shot container with web stopped (no MAC clash, no dual Odoo PIDs).
set_odoo_user_password() {
  local dbname="$1"
  local login="$2"
  local passwd="$3"
  local py_script rc=0 login_b64 pass_b64

  assert_safe_dbname "${dbname}"

  login_b64="$(printf '%s' "${login}" | base64 | tr -d '\n')"
  pass_b64="$(printf '%s' "${passwd}" | base64 | tr -d '\n')"
  py_script="$(cat <<'PY'
import base64
import os
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

  SOVIEZ_RESET_LOGIN_B64="${login_b64}"
  SOVIEZ_RESET_PASS_B64="${pass_b64}"
  set +e
  printf '%s\n' "${py_script}" | run_odoo_maintenance_stdin \
    -d "${dbname}" --stop-after-init
  rc=$?
  set -e
  unset SOVIEZ_RESET_LOGIN_B64 SOVIEZ_RESET_PASS_B64
  return "${rc}"
}

# Create (or refresh) the application DB via a one-shot container (web must be down).
# FORCE_NEW_APP_PASSWORD=1 forces a fresh random password (used by --rebuild).
provision_application_database() {
  local dbname="${SOVIEZ_DB_NAME:-${DEFAULT_APP_DB_NAME}}"
  local install_rc=0
  local app_password=""

  assert_safe_dbname "${dbname}"
  ensure_host_ledger_dir

  wait_for_postgres || {
    ui_error "PostgreSQL not ready — cannot provision application database"
    return 1
  }

  if [[ "${FORCE_NEW_APP_PASSWORD:-0}" == "1" || -z "${SOVIEZ_APP_PASSWORD:-}" ]]; then
    app_password="$(generate_app_password)"
  else
    app_password="${SOVIEZ_APP_PASSWORD}"
  fi
  SOVIEZ_APP_PASSWORD="${app_password}"

  if pg_database_exists "${dbname}"; then
    ui_info "Application database '${dbname}' already present — ensuring admin credentials"
  else
    ui_wait "Creating application database '${dbname}' and installing core modules..."
    log_file "provision_application_database: oneshot -i ${UPGRADE_MODULES} -d ${dbname}"
    set +e
    run_odoo_maintenance \
      -d "${dbname}" \
      -i "${UPGRADE_MODULES}" \
      --without-demo=all \
      --stop-after-init
    install_rc=$?
    set -e
    if (( install_rc != 0 )); then
      ui_error "Database provisioning failed for '${dbname}' (exit ${install_rc}) — see ${LOG_FILE}"
      ui_error "Hint: tail -n 120 ${LOG_FILE}"
      return "${install_rc}"
    fi
    ui_ok "Database '${dbname}' created with core modules"
  fi

  ui_wait "Setting secure login for ${DEFAULT_APP_LOGIN}..."
  if ! set_odoo_user_password "${dbname}" "${DEFAULT_APP_LOGIN}" "${app_password}"; then
    ui_error "Failed to set admin password — see ${LOG_FILE}"
    return 1
  fi
  ui_ok "Admin credentials ready (${DEFAULT_APP_LOGIN} / ${APP_PASSWORD_LEN}-char password)"

  persist_env_key "SOVIEZ_DB_NAME" "${dbname}"
  persist_env_key "SOVIEZ_APP_PASSWORD" "${app_password}"
  SOVIEZ_DB_NAME="${dbname}"
  SOVIEZ_APP_PASSWORD="${app_password}"
  return 0
}

# Shared core pipeline for --new / --formsetup / --rebuild.
# Order: DB → provision (web down) → web → optional tune → optional SSL.
# do_tune: 0|1   do_ssl: 0|1
run_tenant_core_pipeline() {
  local do_tune="${1:-0}"
  local do_ssl="${2:-0}"

  show_progress "Starting PostgreSQL (${DB_CONTAINER})..." start_db_container || return 1

  # Provision before (or with) web stopped — never docker exec -i against a live Odoo.
  SOVIEZ_DB_NAME="${SOVIEZ_DB_NAME:-${DEFAULT_APP_DB_NAME}}"
  show_progress "Provisioning application database (${SOVIEZ_DB_NAME})..." \
    provision_application_database || return 1
  load_env_file

  show_progress "Starting Soviez ERP (${WEB_CONTAINER})..." start_web_container 0 || return 1

  if (( do_tune == 1 )); then
    ui_info "Running intelligent auto-configuration for ${WEB_CONTAINER}..."
    compute_allocation_for_tenant "${WEB_CONTAINER}"
    apply_tenant_resource_tuning || ui_warn "Auto-tuning failed — retry with: sudo ./soviez.sh --formworkers ${WEB_CONTAINER}"
  fi

  if (( do_ssl == 1 )); then
    local domain="${TENANT_DOMAIN:-${SOVIEZ_TENANT_DOMAIN:-}}"
    if [[ -z "${domain}" ]]; then
      ui_error "No tenant domain set — cannot provision HTTPS"
      return 1
    fi
    ui_wait "Provisioning Nginx + HTTPS for ${domain}..."
    if ! provision_tenant_https "${domain}" "${SOVIEZ_HOST_PORT}"; then
      ui_error "HTTPS provisioning failed — see ${LOG_FILE}"
      return 1
    fi
    persist_env_key "SOVIEZ_SSL_MODE" "${SSL_STATUS}"
    persist_env_key "SOVIEZ_PUBLIC_IP" "${PUBLIC_IP}"
    ui_ok "HTTPS pipeline complete for ${domain} (${SSL_STATUS})"
    verify_and_heal_tenant_https "${domain}" "${SOVIEZ_HOST_PORT}"
  fi

  return 0
}

print_tenant_login_banner() {
  local domain="$1"
  local password="${2:-}"

  # Prefer explicit arg, then shell var, then env sheet (formsetup may not have provisioned yet in older runs).
  if [[ -z "${password}" ]]; then
    password="${SOVIEZ_APP_PASSWORD:-}"
  fi
  if [[ -z "${password}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    password="$(grep -E '^SOVIEZ_APP_PASSWORD=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  fi
  if [[ -n "${password}" ]]; then
    SOVIEZ_APP_PASSWORD="${password}"
  fi

  echo ""
  echo -e "${C_GREEN}${C_BOLD}==============================================================${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}🎉 Tenant provisioned successfully!${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}==============================================================${C_RESET}"
  echo -e "  ${C_BOLD}🔗 Login URL:${C_RESET}  ${C_CYAN}https://${domain}${C_RESET}"
  echo -e "  ${C_BOLD}👤 Username:${C_RESET}   ${C_CYAN}${DEFAULT_APP_LOGIN}${C_RESET}"
  if [[ -n "${password}" ]]; then
    echo -e "  ${C_BOLD}🔑 Password:${C_RESET}   ${C_RED}${C_BOLD}${password}${C_RESET}"
  else
    echo -e "  ${C_BOLD}🔑 Password:${C_RESET}   ${C_YELLOW}${C_BOLD}(unavailable — re-run provisioning)${C_RESET}"
  fi
  echo -e "  ${C_YELLOW}${C_BOLD}Save this password now — change it after first login.${C_RESET}"
  echo -e "${C_GREEN}${C_BOLD}==============================================================${C_RESET}"
  echo ""
}

prompt_yes_no_default_no() {
  local question="$1" answer
  read -r -p "${question} (y/N): " answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Soft-delete helpers (never abort the teardown pipeline if a target is already gone).
docker_stop_rm_soft() {
  local name="$1"
  docker stop "${name}" >/dev/null 2>&1 || true
  docker rm -f "${name}" >/dev/null 2>&1 || true
}

docker_volume_rm_soft() {
  local name="$1"
  docker volume rm "${name}" >/dev/null 2>&1 || true
}

docker_network_rm_soft() {
  local name="$1"
  docker network rm "${name}" >/dev/null 2>&1 || true
}

reload_nginx_soft() {
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >>"${LOG_FILE}" 2>&1 && systemctl reload nginx >>"${LOG_FILE}" 2>&1 || true
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

# Optional: set before prompt_domain_confirmed during --change-domain so the
# current tenant's own env/nginx mapping is not treated as a collision.
DOMAIN_UNIQUENESS_EXCLUDE_ENV=""

# Strict domain uniqueness across env sheets + Nginx vhosts.
# Returns 1 on conflict when stdin is a TTY (interactive retry).
# Exits 1 on conflict when non-interactive (piped / scripted).
ensure_domain_is_unique() {
  local domain="$1"
  local exclude_env="${2:-${DOMAIN_UNIQUENESS_EXCLUDE_ENV:-}}"
  local path real real_exclude="" exclude_domain="" existing
  local conflict=0
  local nginx_site=""

  domain="$(normalize_domain "${domain}")"
  if [[ -z "${domain}" ]]; then
    return 0
  fi

  if [[ -n "${exclude_env}" && -e "${exclude_env}" ]]; then
    real_exclude="$(readlink -f "${exclude_env}" 2>/dev/null || printf '%s\n' "${exclude_env}")"
    exclude_domain="$(grep -E '^SOVIEZ_TENANT_DOMAIN=' "${exclude_env}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    exclude_domain="$(normalize_domain "${exclude_domain}")"
  fi

  # --- Source of truth 1: tenant environment sheets ---
  while IFS= read -r path; do
    [[ -n "${path}" && -f "${path}" ]] || continue
    real="$(readlink -f "${path}" 2>/dev/null || printf '%s\n' "${path}")"
    if [[ -n "${real_exclude}" && "${real}" == "${real_exclude}" ]]; then
      continue
    fi
    existing="$(grep -E '^SOVIEZ_TENANT_DOMAIN=' "${path}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
    existing="$(normalize_domain "${existing}")"
    if [[ -n "${existing}" && "${existing}" == "${domain}" ]]; then
      conflict=1
      log_file "Domain conflict: ${domain} already in env sheet ${path}"
      break
    fi
  done < <(collect_tenant_env_paths 2>/dev/null || true)

  # --- Source of truth 2: Nginx vhost files ---
  nginx_site="/etc/nginx/sites-available/soviez-${domain}.conf"
  if (( conflict == 0 )) && [[ -f "${nginx_site}" ]]; then
    # Allow when this vhost belongs to the tenant we are rebinding (same FQDN).
    if [[ -n "${exclude_domain}" && "${exclude_domain}" == "${domain}" ]]; then
      log_file "Domain ${domain} nginx vhost owned by excluded tenant — allowing"
    else
      conflict=1
      log_file "Domain conflict: nginx vhost exists at ${nginx_site}"
    fi
  fi

  if (( conflict == 0 )); then
    return 0
  fi

  echo -e "${C_RED}${C_BOLD}[ERROR] Domain '${domain}' is already mapped to an existing tenant on this server!${C_RESET}" >&2
  log_file "ERROR Domain '${domain}' is already mapped to an existing tenant on this server!"

  # Interactive (TTY): let the caller re-prompt. Non-interactive: hard abort.
  if [[ -t 0 ]]; then
    return 1
  fi
  exit 1
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
    # Reject collisions before DNS / Nginx mutation.
    if ! ensure_domain_is_unique "${d1}"; then
      ui_warn "Choose a different domain that is not already in use on this host."
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

# Idempotent Docker daemon log rotation (prevents unbounded container logs).
ensure_docker_log_rotation() {
  local changed=0
  mkdir -p /etc/docker

  if [[ ! -f "${DOCKER_DAEMON_JSON}" ]]; then
    cat > "${DOCKER_DAEMON_JSON}" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
    changed=1
  else
    set +e
    python3 - "${DOCKER_DAEMON_JSON}" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    data = {}

if not isinstance(data, dict):
    data = {}

want_driver = "json-file"
want_opts = {"max-size": "50m", "max-file": "3"}
changed = False

if data.get("log-driver") != want_driver:
    data["log-driver"] = want_driver
    changed = True

opts = data.get("log-opts")
if not isinstance(opts, dict):
    opts = {}
    changed = True

for key, value in want_opts.items():
    if str(opts.get(key, "")) != value:
        opts[key] = value
        changed = True

data["log-opts"] = opts
if changed:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    sys.exit(0)
sys.exit(1)
PY
    local py_rc=$?
    set -e
    if (( py_rc == 0 )); then
      changed=1
    fi
  fi

  if (( changed == 1 )); then
    ui_wait "Restarting Docker to apply log rotation limits..."
    systemctl restart docker >>"${LOG_FILE}" 2>&1 || {
      ui_error "Docker restart failed after daemon.json update — see ${LOG_FILE}"
      return 1
    }
    ui_ok "Docker log rotation enforced (max-size=50m, max-file=3)"
  else
    ui_ok "Docker log rotation already configured"
  fi
}

# Weekly prune of dangling images / stopped ephemeral containers (volumes untouched).
ensure_docker_weekly_prune() {
  mkdir -p /etc/cron.weekly
  cat > "${DOCKER_PRUNE_CRON}" <<'EOF'
#!/bin/bash
# Soviez ERP — weekly Docker housekeeping (safe for active volumes)
set -euo pipefail
command -v docker >/dev/null 2>&1 || exit 0
docker system prune -af --filter "until=168h" >/dev/null 2>&1 || true
EOF
  chmod 755 "${DOCKER_PRUNE_CRON}"
  ui_ok "Weekly Docker prune cron installed (${DOCKER_PRUNE_CRON})"
}

ensure_fail2ban() {
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    show_progress "Installing Fail2Ban..." apt-get install -y fail2ban || {
      ui_error "Fail2Ban install failed — see ${LOG_FILE}"
      return 1
    }
  else
    ui_ok "Fail2Ban already installed"
  fi

  mkdir -p /var/log/nginx
  touch /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || true

  mkdir -p /etc/fail2ban
  cat > "${FAIL2BAN_JAIL_LOCAL}" <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
port    = ssh
filter  = sshd
maxretry = 5

[nginx-http-auth]
enabled = true
port    = http,https
filter  = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 5

[nginx-botsearch]
enabled = true
port    = http,https
filter  = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2
EOF

  systemctl enable --now fail2ban >>"${LOG_FILE}" 2>&1 || {
    ui_error "Failed to enable Fail2Ban — see ${LOG_FILE}"
    return 1
  }
  # Reload jails after writing jail.local (idempotent).
  systemctl reload fail2ban >>"${LOG_FILE}" 2>&1 || systemctl restart fail2ban >>"${LOG_FILE}" 2>&1 || true
  ui_ok "Fail2Ban active (sshd + nginx-http-auth + nginx-botsearch)"
}

ensure_certbot_nginx_reload_hook() {
  mkdir -p /etc/letsencrypt/renewal-hooks/post
  cat > "${CERTBOT_NGINX_RELOAD_HOOK}" <<'EOF'
#!/bin/bash
# Soviez ERP — reload Nginx after Let's Encrypt renewal
set -euo pipefail
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx
elif command -v nginx >/dev/null 2>&1; then
  nginx -s reload
fi
EOF
  chmod 755 "${CERTBOT_NGINX_RELOAD_HOOK}"
  ui_ok "Certbot post-hook installed (Nginx reload on renew)"
}

print_elite_welcome() {
  local domain="$1"
  local addons_path="$2"
  local index="$3"
  local app_password="${SOVIEZ_APP_PASSWORD:-}"

  if [[ -z "${app_password}" && -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]]; then
    app_password="$(grep -E '^SOVIEZ_APP_PASSWORD=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    [[ -n "${app_password}" ]] && SOVIEZ_APP_PASSWORD="${app_password}"
  fi

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

  print_tenant_login_banner "${domain}" "${app_password}"

  echo -e "  ${C_BOLD}Next steps${C_RESET}"
  echo -e "     1. Open ${C_CYAN}https://${domain}${C_RESET}"
  echo -e "     2. Sign in with ${C_BOLD}admin${C_RESET} and the password shown above (change after first login)"
  echo -e "     3. Enter your Soviez License Code in the License Guard / activation screen"
  echo ""

  echo -e "  ${C_BOLD}Custom addons folder${C_RESET}"
  echo -e "     ${C_CYAN}${addons_path}${C_RESET}"
  echo -e "     ${C_DIM}Drop Odoo modules here, then refresh Apps or run ./soviez.sh --update${C_RESET}"
  print_ssl_status_report "${domain}" "${SSL_STATUS:-}"
  if [[ "${SSL_STATUS:-}" == "selfsigned" ]]; then
    echo -e "  ${C_DIM}Re-attempt Let's Encrypt later: sudo ./soviez.sh --formssl ${domain}${C_RESET}"
    echo ""
  fi
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

  show_progress "Installing base utilities (curl, ca-certificates, python3)..." \
    apt-get install -y curl ca-certificates gnupg lsb-release python3 || true

  install_docker_engine
  show_progress "Configuring Docker log rotation..." ensure_docker_log_rotation || exit 1
  show_progress "Installing weekly Docker prune cron..." ensure_docker_weekly_prune

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
  show_progress "Installing Certbot Nginx reload hook..." ensure_certbot_nginx_reload_hook

  ensure_ufw
  show_progress "Installing Fail2Ban (SSH + Nginx jails)..." ensure_fail2ban || exit 1

  print_green_success "Host environment successfully initialized!"
  echo -e "  Day-2 hardening active: Docker log limits, weekly prune, Fail2Ban, SSL renew hook."
  echo -e "  You can now provision tenants using:"
  echo -e "    ${C_BOLD}sudo ./soviez.sh --new${C_RESET}"
  echo -e "  ${C_DIM}Local wizard path: $(pwd)/soviez.sh${C_RESET}"
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
  # Belt-and-suspenders: uniqueness already enforced in the prompt loop.
  ensure_domain_is_unique "${TENANT_DOMAIN}" || exit 1
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
  SOVIEZ_MIGRATION_SECRET="$(generate_migration_secret)"
  SOVIEZ_HOST_PORT="$(find_free_host_port "${MULTI_PORT_START}")"

  cat > "${ENV_FILE}" <<EOF
SOVIEZ_INSTANCE_INDEX=${next_index}
SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}
SOVIEZ_CONTAINER_MAC=${SOVIEZ_CONTAINER_MAC}
SOVIEZ_DB_PASSWORD=${SOVIEZ_DB_PASSWORD}
SOVIEZ_ADMIN_PASSWORD=${SOVIEZ_ADMIN_PASSWORD}
SOVIEZ_MIGRATION_SECRET=${SOVIEZ_MIGRATION_SECRET}
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
SOVIEZ_DB_NAME=${DEFAULT_APP_DB_NAME}
EOF
  chmod 600 "${ENV_FILE}"
  SOVIEZ_DB_NAME="${DEFAULT_APP_DB_NAME}"
  load_env_file

  show_progress "Pulling container images..." bash -c \
    "docker pull '${APP_IMAGE}' && docker pull '${DB_IMAGE}'"

  show_progress "Creating network and volumes..." ensure_network_and_volumes

  # Shared pipeline: DB → web → provision → tune → SSL
  if ! run_tenant_core_pipeline "${AUTO_TUNE_ON_NEW}" 1; then
    ui_error "Tenant core pipeline failed — see ${LOG_FILE}"
    exit 1
  fi

  print_elite_welcome \
    "${TENANT_DOMAIN}" \
    "${CUSTOM_ADDONS_HOST_PATH}" \
    "${next_index}"
}

# ===========================================================================
# MODE: purge — irreversible tenant obliteration
# ===========================================================================
mode_purge() {
  require_root --purge
  ensure_log_file
  require_cmd docker

  if [[ -z "${PURGE_TENANT_REF}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --purge <tenant>"
    ui_error "Example: sudo ./soviez.sh --purge soviez-web-1"
    exit 1
  fi

  load_tenant_topology_from_ref "${PURGE_TENANT_REF}"
  resolve_custom_addons_host_path

  local tenant_name="${WEB_CONTAINER}"
  local domain="${SOVIEZ_TENANT_DOMAIN:-${TENANT_DOMAIN:-}}"
  local addons_tree conf_tree typed

  # Parent of .../addons → /soviez/soviez_web_N
  addons_tree=""
  if [[ -n "${CUSTOM_ADDONS_HOST_PATH:-}" ]]; then
    addons_tree="$(dirname "${CUSTOM_ADDONS_HOST_PATH}")"
  fi
  conf_tree="${SOVIEZ_VOLUME_ROOT}/${WEB_CONTAINER}"

  print_border_box "Soviez ERP — PURGE (IRREVERSIBLE)" \
    "Tenant: ${C_BOLD}${tenant_name}${C_RESET}" \
    "Domain: ${C_BOLD}${domain:-unknown}${C_RESET}" \
    "Env: ${ENV_FILE}" \
    "" \
    "This destroys containers, volumes, network, env sheet, Nginx, and host dirs."

  echo ""
  echo -e "${C_RED}${C_BOLD}⚠️  WARNING: This will irreversibly destroy ALL data, containers, and configs for ${tenant_name}.${C_RESET}"
  read -r -p "To proceed, type the exact tenant name: " typed
  if [[ "${typed}" != "${tenant_name}" ]]; then
    ui_error "Aborted — typed name does not match '${tenant_name}'."
    exit 1
  fi

  ui_wait "Stopping and removing containers..."
  docker_stop_rm_soft "${WEB_CONTAINER}"
  docker_stop_rm_soft "${DB_CONTAINER}"
  ui_ok "Containers removed (or already absent)"

  ui_wait "Removing Docker volumes..."
  docker_volume_rm_soft "${DB_VOLUME}"
  docker_volume_rm_soft "${FILESTORE_VOLUME}"
  ui_ok "Volumes removed (or already absent)"

  ui_wait "Removing Docker network ${NETWORK_NAME}..."
  docker_network_rm_soft "${NETWORK_NAME}"
  ui_ok "Network removed (or already absent)"

  if [[ -f "${ENV_FILE}" ]]; then
    rm -f "${ENV_FILE}" || true
    ui_ok "Deleted env sheet ${ENV_FILE}"
  fi

  if [[ -n "${conf_tree}" && -d "${conf_tree}" ]]; then
    rm -rf "${conf_tree}" || true
    ui_ok "Deleted runtime config tree ${conf_tree}"
  fi

  if [[ -n "${addons_tree}" && -d "${addons_tree}" && "${addons_tree}" == /soviez/* ]]; then
    rm -rf "${addons_tree}" || true
    ui_ok "Deleted custom addons tree ${addons_tree}"
  fi

  if [[ -n "${domain}" ]]; then
    remove_nginx_site_for_domain "${domain}"
    reload_nginx_soft
    ui_ok "Nginx vhost removed for ${domain}"
  fi

  print_green_success "Tenant ${tenant_name} purged — no residual stack assets remain."
  echo -e "  Log: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo ""
}

# ===========================================================================
# MODE: rebuild — wipe DB/filestore; keep domain, env, custom addons
# ===========================================================================
mode_rebuild() {
  require_root --rebuild
  ensure_log_file
  require_cmd docker
  require_cmd python3
  ensure_host_ledger_dir

  if [[ -z "${REBUILD_TENANT_REF}" ]]; then
    ui_error "Usage: sudo ./soviez.sh --rebuild <tenant>"
    ui_error "Example: sudo ./soviez.sh --rebuild soviez-web-1"
    exit 1
  fi

  load_tenant_topology_from_ref "${REBUILD_TENANT_REF}"
  resolve_custom_addons_host_path
  require_complete_env

  local tenant_name="${WEB_CONTAINER}"
  local domain="${SOVIEZ_TENANT_DOMAIN:-${TENANT_DOMAIN:-}}"

  print_border_box "Soviez ERP — Rebuild Tenant" \
    "Tenant: ${C_BOLD}${tenant_name}${C_RESET}" \
    "Domain: ${C_BOLD}${domain:-unknown}${C_RESET}" \
    "Keeps: env sheet, custom addons, Nginx/domain" \
    "Wipes: Postgres volume + filestore volume + application DB"

  if ! prompt_yes_no_default_no "Are you sure you want to rebuild ${tenant_name}? This will wipe the database and filestore, but keep custom addons and domain."; then
    ui_error "Rebuild aborted."
    exit 1
  fi

  ui_wait "Stopping and removing containers..."
  docker_stop_rm_soft "${WEB_CONTAINER}"
  docker_stop_rm_soft "${DB_CONTAINER}"

  ui_wait "Dropping data volumes..."
  docker_volume_rm_soft "${DB_VOLUME}"
  docker_volume_rm_soft "${FILESTORE_VOLUME}"

  ensure_custom_addons_dir
  load_env_file
  show_progress "Recreating network and volumes..." ensure_network_and_volumes

  # Fresh stack + new app password; no retune/SSL (domain/Nginx kept).
  FORCE_NEW_APP_PASSWORD=1
  if ! run_tenant_core_pipeline 0 0; then
    ui_error "Rebuild core pipeline failed — see ${LOG_FILE}"
    exit 1
  fi

  print_green_success "Tenant ${tenant_name} rebuilt."
  print_tenant_login_banner "${domain:-localhost}"
  echo -e "  Custom addons preserved at: ${C_CYAN}${CUSTOM_ADDONS_HOST_PATH}${C_RESET}"
  echo -e "  Log: ${C_DIM}${LOG_FILE}${C_RESET}"
  echo ""
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
    "update tenant.soviez.conf → apply Docker limits → start web."

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

  local target_index do_tune=0
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

  # Honor original --new auto-tune choice when healing.
  [[ "${SOVIEZ_AUTO_TUNE:-0}" == "1" ]] && do_tune=1

  # Shared pipeline: DB (if missing) → web (if missing) → provision → tune → SSL
  if ! run_tenant_core_pipeline "${do_tune}" 1; then
    ui_error "Formsetup core pipeline failed — see ${LOG_FILE}"
    exit 1
  fi

  print_elite_welcome \
    "${TENANT_DOMAIN}" \
    "${CUSTOM_ADDONS_HOST_PATH}" \
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

  ui_info "Rotating internal admin_passwd (SOVIEZ_ADMIN_PASSWORD)..."
  SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
  persist_env_key "SOVIEZ_ADMIN_PASSWORD" "${SOVIEZ_ADMIN_PASSWORD}"
  load_env_file

  ensure_network_and_volumes
  docker rm -f "${WEB_CONTAINER}" 2>/dev/null || true
  show_progress "Pulling ${APP_IMAGE}..." docker pull "${APP_IMAGE}"
  show_progress "Recycling ${WEB_CONTAINER}..." launch_web_container

  print_green_success "Internal admin_passwd rotated (SOVIEZ_ADMIN_PASSWORD)."
  echo -e "  Stored only in ${C_BOLD}${ENV_FILE}${C_RESET} — not printed to the terminal."
  echo -e "  Retrieve (root): ${C_DIM}grep '^SOVIEZ_ADMIN_PASSWORD=' ${ENV_FILE}${C_RESET}"
  ui_ok "Web container recycled. Volumes preserved."
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
  ensure_migration_secret || return 1
  # Prefer one-shot maintenance container (same pattern as --update); avoids -u odoo if absent.
  if docker run --rm \
      --network "${NETWORK_NAME}" \
      -e POSTGRES_USER="${DB_APP_USER}" \
      -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -e SOVIEZ_MIGRATION_SECRET="${SOVIEZ_MIGRATION_SECRET}" \
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
  echo -e "  Select database ${C_CYAN}${STAGE_DB_NAME}${C_RESET} at login (or via dbfilter)"
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
  SOVIEZ_RESET_LOGIN_B64="${login_b64}"
  SOVIEZ_RESET_PASS_B64="${pass_b64}"
  printf '%s\n' "${py_script}" | run_odoo_maintenance_stdin \
    -d "${RESET_DB}" --stop-after-init
  rc=$?
  unset SOVIEZ_RESET_LOGIN_B64 SOVIEZ_RESET_PASS_B64
  set -e

  # Restart web if it was part of a live tenant (maintenance stops it).
  if container_exists "${WEB_CONTAINER}" && ! container_running "${WEB_CONTAINER}"; then
    docker start "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1 || true
  fi

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
  # Ignore this tenant's own env/nginx mapping while choosing a replacement FQDN.
  DOMAIN_UNIQUENESS_EXCLUDE_ENV="${ENV_FILE}"
  prompt_domain_confirmed
  DOMAIN_UNIQUENESS_EXCLUDE_ENV=""
  new_domain="${TENANT_DOMAIN}"

  if [[ -n "${old_domain}" && "${old_domain}" == "${new_domain}" ]]; then
    ui_warn "New domain matches the current domain — nothing to change"
    exit 0
  fi

  # Final gate before DNS / Nginx mutation (excludes current env sheet).
  ensure_domain_is_unique "${new_domain}" "${ENV_FILE}" || exit 1

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
  purge)
    mode_purge
    ;;
  rebuild)
    mode_rebuild
    ;;
  *)
    ui_error "Unknown mode: ${MODE}"
    exit 1
    ;;
esac
