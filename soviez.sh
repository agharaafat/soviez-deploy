#!/usr/bin/env bash
# Soviez ERP — production onboarding wizard (Ubuntu/Debian)
#
# Modes:
#   ./soviez.sh            | --init    Host environment bootstrap (apt, Docker, Nginx, Certbot, UFW)
#   ./soviez.sh --new                  Provision isolated multi-tenant instance + DNS/SSL/addons
#   ./soviez.sh --formsetup            Resume / heal the latest half-configured tenant (idempotent)
#   ./soviez.sh --formssl [domain]     Diagnose / repair tenant HTTPS (LE or self-signed Cloudflare Full)
#   ./soviez.sh --update               Pull soviez/soviez-erp:latest and recycle web runners
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
readonly CUSTOM_ADDONS_CONTAINER_PATH="/var/lib/odoo/custom_addons"
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
    --recoverdbpass)
      MODE="recover"
      ;;
    -h|--help)
      cat <<'USAGE'
Soviez ERP — production onboarding wizard

Usage:
  ./soviez.sh [--init]              Bootstrap host (apt, Docker, Nginx, Certbot, UFW)
  ./soviez.sh --new                 Provision a new isolated tenant (domain + SSL + addons)
  ./soviez.sh --formsetup           Resume / heal latest half-configured tenant (idempotent)
  ./soviez.sh --formssl [domain]    Diagnose / repair HTTPS (Let's Encrypt or self-signed)
  ./soviez.sh --update              Pull latest ERP image and recycle web containers
  ./soviez.sh --recoverdbpass       Rotate Database Master Password
  ./soviez.sh --help                Show this help

Images:
  soviez/soviez-erp:latest
  postgres:16

SSL strategy:
  Explicit public-IP listen (beats Virtualmin IP:443), self-signed baseline,
  then Certbot. Post-provision curl verify + self-heal if routing is stolen.

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
      if [[ "${MODE}" == "formssl" && -z "${FORMSSL_DOMAIN}" ]]; then
        FORMSSL_DOMAIN="${arg}"
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
  CUSTOM_ADDONS_HOST_PATH=""
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
  CUSTOM_ADDONS_HOST_PATH="/etc/soviez_web_${index}/addons"
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

ensure_postgres_container() {
  if container_running "${DB_CONTAINER}"; then
    log_file "DB ${DB_CONTAINER} already running"
  elif container_exists "${DB_CONTAINER}"; then
    docker start "${DB_CONTAINER}" >/dev/null
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
    ui_ok "Web ERP already running (${WEB_CONTAINER})"
    return 0
  fi
  if container_exists "${WEB_CONTAINER}"; then
    ui_wait "Starting stopped web ERP (${WEB_CONTAINER})..."
    docker start "${WEB_CONTAINER}" >>"${LOG_FILE}" 2>&1
    ui_ok "Web ERP started (${WEB_CONTAINER})"
    return 0
  fi
  ui_wait "Creating web ERP (${WEB_CONTAINER})..."
  launch_web_container
  ui_ok "Web ERP created (${WEB_CONTAINER})"
}

ensure_custom_addons_dir() {
  if [[ -z "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    return 0
  fi
  mkdir -p "${CUSTOM_ADDONS_HOST_PATH}"
  chmod 755 "$(dirname "${CUSTOM_ADDONS_HOST_PATH}")" 2>/dev/null || true
  chmod 755 "${CUSTOM_ADDONS_HOST_PATH}"
  # Friendly README on first create
  if [[ ! -f "${CUSTOM_ADDONS_HOST_PATH}/README.txt" ]]; then
    cat > "${CUSTOM_ADDONS_HOST_PATH}/README.txt" <<EOF
Soviez ERP — custom addons drop folder for ${WEB_CONTAINER}

Place Odoo/Soviez modules here (each module in its own subdirectory).
They are mounted read/write into the container at:
  ${CUSTOM_ADDONS_CONTAINER_PATH}

After dropping a module, update the database apps list from the UI
or run: sudo ./soviez.sh --update
EOF
  fi
}

launch_web_container() {
  local addons_cli
  local -a volume_args=()

  ensure_host_ledger_dir
  ensure_custom_addons_dir

  volume_args+=(
    -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore"
    -v "${HOST_SOVIEZ_DIR}:/root/.soviez"
  )

  addons_cli="/opt/soviez-erp/addons,/opt/soviez-erp/odoo/addons"
  if [[ -n "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    volume_args+=(
      -v "${CUSTOM_ADDONS_HOST_PATH}:${CUSTOM_ADDONS_CONTAINER_PATH}"
    )
    addons_cli="${addons_cli},${CUSTOM_ADDONS_CONTAINER_PATH}"
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
    "${volume_args[@]}" \
    "${APP_IMAGE}" \
    python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
      --addons-path="${addons_cli}" \
      --db_host="${DB_CONTAINER}" \
      --db_port=5432 \
      --db_user=soviez \
      --db_password="${SOVIEZ_DB_PASSWORD}" \
      --data-dir=/root/.local/share/Odoo \
      --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" >/dev/null
}

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

nginx_site_has_443() {
  local site
  site="$(nginx_site_path "$1")"
  [[ -f "${site}" ]] || return 1
  grep -Eq 'listen[[:space:]]+[^;]*443' "${site}" 2>/dev/null
}

# Write complete dual-stack vhost: :80 ACME + HTTPS redirect, :443 SSL proxy to ERP.
# ssl_kind: selfsigned | letsencrypt
# Force-hijack: bind listen ${PUBLIC_IP}:80/443 so Virtualmin IP:443 cannot steal traffic.
write_nginx_site() {
  local domain="$1"
  local host_port="$2"
  local ssl_kind="${3:-selfsigned}"
  local site_file enabled_link crt_file key_file bind_ip

  site_file="$(nginx_site_path "${domain}")"
  enabled_link="/etc/nginx/sites-enabled/soviez-${domain}.conf"
  bind_ip="$(ensure_public_bind_ip)"

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

server {
    listen ${bind_ip}:80;
    server_name ${domain};

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
  log_file "Wrote Nginx site ${site_file} ssl_kind=${ssl_kind} bind=${bind_ip} crt=${crt_file}"
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

# Return 0 when https://domain looks like a reachable Soviez/Odoo edge (not a dead panel).
verify_tenant_https_http_code() {
  local domain="$1"
  local body_file code
  body_file="$(mktemp)"

  set +e
  code="$(curl -k -sS -L --max-time 5 -o "${body_file}" -w "%{http_code}" \
    -H "Host: ${domain}" \
    "https://${domain}/" 2>>"${LOG_FILE}")"
  local curl_rc=$?
  set -e

  log_file "HTTPS verify ${domain} curl_rc=${curl_rc} http_code=${code:-}"

  if (( curl_rc != 0 )) || [[ -z "${code}" || "${code}" == "000" ]]; then
    rm -f "${body_file}"
    return 1
  fi

  case "${code}" in
    200|301|302|303|307|308|404)
      # Reject obvious alien control-panel HTML when status otherwise looks fine.
      if grep -Eiq 'virtualmin|webmin|cpanel|plesk|cyberpanel|directadmin|ispconfig' "${body_file}" 2>/dev/null \
          && ! grep -Eiq 'odoo|soviez|web/database|web/login|web/session' "${body_file}" 2>/dev/null; then
        log_file "HTTPS verify ${domain}: alien panel HTML detected despite HTTP ${code}"
        rm -f "${body_file}"
        return 1
      fi
      rm -f "${body_file}"
      LAST_HTTPS_CODE="${code}"
      return 0
      ;;
    *)
      rm -f "${body_file}"
      LAST_HTTPS_CODE="${code}"
      return 1
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

  ui_wait "Verifying HTTPS route https://${domain} (max 5s)..."
  if verify_tenant_https_http_code "${domain}"; then
    ui_ok "HTTPS verification passed (HTTP ${LAST_HTTPS_CODE})"
    return 0
  fi

  ui_warn "HTTPS verification failed (HTTP ${LAST_HTTPS_CODE:-(curl error)}) — running self-healing diagnostics..."
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

  ui_wait "Re-verifying HTTPS route https://${domain}..."
  if verify_tenant_https_http_code "${domain}"; then
    ui_ok "HTTPS verification passed after heal (HTTP ${LAST_HTTPS_CODE})"
    return 0
  fi

  dump_port_capture_diagnostics "${domain}" "${bind_ip}"
  ui_error "Automated hijack attempts exhausted — traffic for ${domain} is still not reaching Soviez."
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
  if [[ -z "${CUSTOM_ADDONS_HOST_PATH}" && -n "${INSTANCE_INDEX}" ]]; then
    CUSTOM_ADDONS_HOST_PATH="/etc/soviez_web_${INSTANCE_INDEX}/addons"
  fi
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
    echo -e "  ${C_YELLOW}⚠️  SSL Note: Using Cloudflare? Ensure your Cloudflare SSL/TLS encryption mode is set to 'Full' so your site opens securely immediately!${C_RESET}"
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

  show_progress "Installing Certbot (nginx plugin)..." \
    apt-get install -y certbot python3-certbot-nginx || exit 1

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

  print_elite_welcome \
    "${TENANT_DOMAIN}" \
    "${CUSTOM_ADDONS_HOST_PATH}" \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "${next_index}"
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
  if [[ -z "${CUSTOM_ADDONS_HOST_PATH}" ]]; then
    CUSTOM_ADDONS_HOST_PATH="/etc/soviez_web_${INSTANCE_INDEX}/addons"
  fi
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
    echo -e "  ${C_YELLOW}Self-Signed setup optimized for Cloudflare Full mode.${C_RESET}"
    echo -e "  ${C_YELLOW}⚠️  SSL Note: Using Cloudflare? Ensure your Cloudflare SSL/TLS encryption mode is set to 'Full' so your site opens securely immediately!${C_RESET}"
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
    if [[ -z "${CUSTOM_ADDONS_HOST_PATH}" && -n "${INSTANCE_INDEX}" ]]; then
      CUSTOM_ADDONS_HOST_PATH="/etc/soviez_web_${INSTANCE_INDEX}/addons"
    fi

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
# Dispatch
# ===========================================================================
ensure_log_file

case "${MODE}" in
  init)
    mode_init
    ;;
  new)
    mode_new
    ;;
  formsetup)
    mode_formsetup
    ;;
  formssl)
    mode_formssl
    ;;
  update)
    mode_update
    ;;
  recover)
    mode_recover
    ;;
  *)
    ui_error "Unknown mode: ${MODE}"
    exit 1
    ;;
esac
