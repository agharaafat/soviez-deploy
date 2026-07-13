#!/usr/bin/env bash
# Soviez ERP — multi-instance SaaS appliance bootstrap (empty-directory safe)
# Uses pure `docker run` only — no docker-compose.yml or host config mounts required.
#
# Usage:
#   ./setup.sh                 # install / relaunch primary cluster (.soviez.env)
#   ./setup.sh --update        # pull :latest + schema upgrade + recycle primary web
#   ./setup.sh --new           # provision next isolated multi-tenant instance
#   ./setup.sh --recoverdbpass # rotate Database Master Password + recycle web
set -euo pipefail

readonly APP_IMAGE="soviez/soviez-erp:latest"
readonly DB_IMAGE="postgres:latest"
readonly UPGRADE_MODULES="base,local_license_guard,mail,web,web_enterprise,soviez_web_ui,web_studio"
readonly PORT_SCAN_MAX=8999
readonly PRIMARY_PORT_START=8069
readonly MULTI_PORT_START=8073

# Mutable topology (primary defaults; --new overrides via apply_topology_indexed)
ENV_FILE=".soviez.env"
NETWORK_NAME="soviez_network"
DB_CONTAINER="soviez-db"
WEB_CONTAINER="soviez-web"
DB_VOLUME="soviez_db_data"
FILESTORE_VOLUME="soviez_filestore"
INSTANCE_INDEX=""
PORT_SCAN_START="${PRIMARY_PORT_START}"

# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------
MODE="install"
for arg in "$@"; do
  case "${arg}" in
    --update)
      MODE="update"
      ;;
    --new)
      MODE="new"
      ;;
    --recoverdbpass)
      MODE="recover"
      ;;
    -h|--help)
      cat <<'USAGE'
Soviez ERP bootstrap — multi-instance SaaS appliance

Usage:
  ./setup.sh                 Install or relaunch the primary Docker cluster
  ./setup.sh --update        Pull :latest images, upgrade schemas, recycle web
  ./setup.sh --new           Provision the next isolated multi-tenant instance
  ./setup.sh --recoverdbpass Rotate Database Master Password and recycle web
  ./setup.sh --help          Show this help

Images (rolling):
  soviez/soviez-erp:latest
  postgres:latest
USAGE
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: ${arg}" >&2
      echo "[ERROR] Try: ./setup.sh --help" >&2
      exit 1
      ;;
  esac
done

umask 077

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

print_green_success() {
  local GREEN=$'\033[0;32m'
  local BOLD=$'\033[1m'
  local NC=$'\033[0m'
  echo ""
  echo -e "${GREEN}${BOLD}==============================================================${NC}"
  echo -e "${GREEN}${BOLD}  $*${NC}"
  echo -e "${GREEN}${BOLD}==============================================================${NC}"
  echo ""
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

require_cmd docker
require_cmd python3

resolve_instance_root() {
  # Prefer /root when writable (production appliance); else setup working directory.
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
  # Host-side security ledger (~/.soviez) — must persist across container recycles.
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
  # CRITICAL: create hardened host ledger before any container spawn so
  # .shadow_lock / .deployment_ledger survive --update / recreate cycles.
  mkdir -p "${HOST_SOVIEZ_DIR}"
  chmod 700 "${HOST_SOVIEZ_DIR}"
  log_info "Host security ledger ready: ${HOST_SOVIEZ_DIR} → /root/.soviez (mode 700)"
}

# Initialize host ledger immediately — before any docker run / compose path.
ensure_host_ledger_dir

# ---------------------------------------------------------------------------
# Port occupancy probe — ss → netstat → bash /dev/tcp
# Returns 0 when busy, 1 when free.
# ---------------------------------------------------------------------------
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
      log_warn "Port ${port} is busy, probing next system socket..."
      port=$((port + 1))
    else
      echo "${port}"
      return 0
    fi
  done
  log_error "No free TCP port available in range ${start}-${PORT_SCAN_MAX}."
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

persist_host_port() {
  persist_env_key "SOVIEZ_HOST_PORT" "$1"
}

load_env_file() {
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
}

container_exists() {
  docker ps -a --format '{{.Names}}' | grep -Fxq "$1"
}

container_running() {
  docker ps --format '{{.Names}}' | grep -Fxq "$1"
}

apply_topology_primary() {
  ENV_FILE="$(pwd)/.soviez.env"
  # Prefer /root primary env when present (appliance layout).
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
  PORT_SCAN_START="${MULTI_PORT_START}"
}

find_next_instance_index() {
  local max=0
  local path base num
  local has_primary=0

  if [[ -f "${INSTANCE_ROOT}/.soviez.env" || -f "$(pwd)/.soviez.env" ]]; then
    has_primary=1
  fi
  if container_exists "soviez-web" || container_exists "soviez-db"; then
    has_primary=1
  fi

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

  # Also scan running/stopped indexed web containers.
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
  elif (( has_primary == 1 )); then
    echo 1
  else
    # No primary yet — still start indexed fleet at 1 per --new contract.
    echo 1
  fi
}

print_master_password_alert() {
  local password="$1"
  local headline="${2:-DATABASE MASTER PASSWORD}"
  local RED=$'\033[0;31m'
  local BOLD=$'\033[1m'
  local NC=$'\033[0m'

  echo ""
  echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
  echo -e "${RED}${BOLD}!!                                                            !!${NC}"
  echo -e "${RED}${BOLD}!!  ${headline}${NC}"
  echo -e "${RED}${BOLD}!!                                                            !!${NC}"
  echo -e "${RED}${BOLD}!!  ${password}${NC}"
  echo -e "${RED}${BOLD}!!                                                            !!${NC}"
  echo -e "${RED}${BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${NC}"
  echo -e "${RED}${BOLD}WARNING:${NC} ${RED}Copy and save this Database Master Password NOW.${NC}"
  echo -e "${RED}It is required to provision databases and manage system assets${NC}"
  echo -e "${RED}in the Web Database Manager. Store it in your password vault.${NC}"
  echo -e "${RED}It will not be shown again unless you run:${NC}"
  echo -e "${RED}  ./setup.sh --recoverdbpass${NC}"
  echo ""
}

ensure_network_and_volumes() {
  log_info "Ensuring private bridge network '${NETWORK_NAME}'..."
  docker network create "${NETWORK_NAME}" 2>/dev/null || true

  log_info "Ensuring persistent volumes..."
  docker volume create "${DB_VOLUME}" >/dev/null
  docker volume create "${FILESTORE_VOLUME}" >/dev/null
}

wait_for_postgres() {
  log_info "Waiting for PostgreSQL readiness (${DB_CONTAINER})..."
  for _ in $(seq 1 45); do
    if docker exec "${DB_CONTAINER}" pg_isready -U soviez -d postgres >/dev/null 2>&1; then
      log_info "PostgreSQL is ready."
      return 0
    fi
    sleep 1
  done
  log_error "PostgreSQL did not become ready in time. Inspect: docker logs ${DB_CONTAINER}"
  return 1
}

ensure_postgres_container() {
  if container_running "${DB_CONTAINER}"; then
    log_info "Database container '${DB_CONTAINER}' already running — leaving it in place."
  elif container_exists "${DB_CONTAINER}"; then
    log_info "Starting existing database container '${DB_CONTAINER}'..."
    docker start "${DB_CONTAINER}" >/dev/null
  else
    log_info "Launching PostgreSQL (${DB_CONTAINER}) image ${DB_IMAGE} on ${NETWORK_NAME}..."
    # POSTGRES_DB=postgres: do NOT pre-create an empty application schema.
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

launch_web_container() {
  log_info "Launching Soviez ERP (${WEB_CONTAINER}) image ${APP_IMAGE}..."
  log_info "Host publish map: ${SOVIEZ_HOST_PORT} → container 8069"
  log_info "Pinned MAC address: ${SOVIEZ_CONTAINER_MAC}"
  log_info "DB host (cluster DNS): ${DB_CONTAINER}"
  log_info "Security ledger bind: ${HOST_SOVIEZ_DIR} → /root/.soviez"

  ensure_host_ledger_dir

  # Do not set POSTGRES_DB on the web container — Odoo must boot with an empty
  # database list and present the interactive Web Database Manager.
  docker run -d \
    --name "${WEB_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    --mac-address "${SOVIEZ_CONTAINER_MAC}" \
    -p "${SOVIEZ_HOST_PORT}:8069" \
    -e POSTGRES_USER=soviez \
    -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore" \
    -v "${HOST_SOVIEZ_DIR}:/root/.soviez" \
    "${APP_IMAGE}" \
    python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
      --db_host="${DB_CONTAINER}" \
      --db_port=5432 \
      --db_user=soviez \
      --db_password="${SOVIEZ_DB_PASSWORD}" \
      --data-dir=/root/.local/share/Odoo \
      --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" >/dev/null
}

list_odoo_databases() {
  # Prefer explicit override, else discover non-template app DBs on the cluster.
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
  # Force libsass / web.assets_* recompile so premium login SCSS and UI bundles
  # are never served stale after --update.
  local dbname="$1"
  log_info "Purging compiled frontend assets for '${dbname}' (force layout recompile)..."
  if ! docker exec "${DB_CONTAINER}" \
    psql -U soviez -d "${dbname}" -v ON_ERROR_STOP=1 -c \
    "DELETE FROM ir_attachment
     WHERE url LIKE '/web/assets/%'
        OR url LIKE '/web/content/%assets%'
        OR name ILIKE 'web.assets_%'
        OR name ILIKE 'web_enterprise.assets_%'
        OR name ILIKE '%.assets_%.min.js'
        OR name ILIKE '%.assets_%.min.css';" >/dev/null; then
    log_error "Frontend asset purge failed for database '${dbname}'."
    return 1
  fi
  log_info "Frontend asset cache cleared for '${dbname}'."
}

run_schema_upgrades() {
  local dbname
  local dbs
  local count=0
  local upgrade_rc=0

  ensure_host_ledger_dir

  mapfile -t dbs < <(list_odoo_databases)
  if ((${#dbs[@]} == 0)); then
    log_warn "No application databases found to upgrade — skipping -u migration pass."
    log_warn "Create a database via the Web Database Manager, then re-run ./setup.sh --update."
    return 0
  fi

  for dbname in "${dbs[@]}"; do
    [[ -z "${dbname}" ]] && continue
    # Sanitize: allow only common Odoo DB name characters.
    if [[ ! "${dbname}" =~ ^[A-Za-z0-9_:-]+$ ]]; then
      log_error "Refusing to upgrade unsafe database name: ${dbname}"
      return 1
    fi
    count=$((count + 1))
    log_info "Running schema upgrade on database '${dbname}' (modules: ${UPGRADE_MODULES})..."
    set +e
    docker run --rm \
      --network "${NETWORK_NAME}" \
      --mac-address "${SOVIEZ_CONTAINER_MAC}" \
      -e POSTGRES_USER=soviez \
      -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
      -v "${FILESTORE_VOLUME}:/root/.local/share/Odoo/filestore" \
      -v "${HOST_SOVIEZ_DIR}:/root/.soviez" \
      "${APP_IMAGE}" \
      python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
        --db_host="${DB_CONTAINER}" \
        --db_port=5432 \
        --db_user=soviez \
        --db_password="${SOVIEZ_DB_PASSWORD}" \
        --data-dir=/root/.local/share/Odoo \
        --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" \
        -d "${dbname}" \
        -u "${UPGRADE_MODULES}" \
        --stop-after-init
    upgrade_rc=$?
    set -e
    if (( upgrade_rc != 0 )); then
      log_error "Schema upgrade failed for '${dbname}' (exit ${upgrade_rc})."
      log_error "Leaving live web runner untouched to avoid a corrupted cut-over."
      return "${upgrade_rc}"
    fi
    log_info "Schema upgrade finished for '${dbname}'."
    purge_frontend_assets "${dbname}" || return 1
  done

  log_info "Upgraded ${count} database(s) with frontend asset purge."
}

require_complete_env() {
  if [[ -z "${SOVIEZ_CONTAINER_MAC:-}" || -z "${SOVIEZ_DB_PASSWORD:-}" || -z "${SOVIEZ_HOST_PORT:-}" || -z "${SOVIEZ_ADMIN_PASSWORD:-}" ]]; then
    log_error "${ENV_FILE} is missing SOVIEZ_CONTAINER_MAC, SOVIEZ_DB_PASSWORD, SOVIEZ_ADMIN_PASSWORD, or SOVIEZ_HOST_PORT."
    exit 1
  fi
}

# ===========================================================================
# MODE: recover — rotate master password on primary cluster
# ===========================================================================
if [[ "${MODE}" == "recover" ]]; then
  apply_topology_primary
  if [[ ! -f "${ENV_FILE}" ]]; then
    log_error "No Soviez ERP installation found to recover."
    exit 1
  fi

  load_env_file
  if [[ -z "${SOVIEZ_CONTAINER_MAC:-}" || -z "${SOVIEZ_DB_PASSWORD:-}" || -z "${SOVIEZ_HOST_PORT:-}" ]]; then
    log_error "${ENV_FILE} is incomplete — cannot recover master password."
    exit 1
  fi

  log_info "Rotating Database Master Password (SOVIEZ_ADMIN_PASSWORD)..."
  SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
  persist_env_key "SOVIEZ_ADMIN_PASSWORD" "${SOVIEZ_ADMIN_PASSWORD}"
  load_env_file

  ensure_network_and_volumes
  log_info "Recycling application container '${WEB_CONTAINER}'..."
  docker rm -f "${WEB_CONTAINER}" 2>/dev/null || true
  log_info "Pulling application image ${APP_IMAGE}..."
  docker pull "${APP_IMAGE}"
  launch_web_container

  print_master_password_alert \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "MASTER PASSWORD RESET — APPLICATION LAYER RECYCLED"
  log_info "Master Password successfully reset. Existing databases and volumes were preserved."
  log_info "UI: http://localhost:${SOVIEZ_HOST_PORT}"
  exit 0
fi

# ===========================================================================
# MODE: update — pull :latest, upgrade schemas, recycle web
# ===========================================================================
if [[ "${MODE}" == "update" ]]; then
  apply_topology_primary
  if [[ ! -f "${ENV_FILE}" ]]; then
    log_error "No Soviez ERP installation found to update."
    log_error "Missing baseline environment file: ${ENV_FILE}"
    exit 1
  fi

  log_info "Loading baseline parameters from ${ENV_FILE}..."
  load_env_file
  require_complete_env

  # Restore topology names if persisted in env (future-proof).
  NETWORK_NAME="${SOVIEZ_NETWORK_NAME:-${NETWORK_NAME}}"
  DB_CONTAINER="${SOVIEZ_DB_CONTAINER:-${DB_CONTAINER}}"
  WEB_CONTAINER="${SOVIEZ_WEB_CONTAINER:-${WEB_CONTAINER}}"
  DB_VOLUME="${SOVIEZ_DB_VOLUME:-${DB_VOLUME}}"
  FILESTORE_VOLUME="${SOVIEZ_FILESTORE_VOLUME:-${FILESTORE_VOLUME}}"

  log_info "Force-pulling rolling images..."
  docker pull "${APP_IMAGE}"
  docker pull "${DB_IMAGE}"

  ensure_network_and_volumes
  if ! container_running "${DB_CONTAINER}"; then
    if container_exists "${DB_CONTAINER}"; then
      docker start "${DB_CONTAINER}" >/dev/null
    else
      log_error "Database container '${DB_CONTAINER}' not found — cannot upgrade schemas."
      exit 1
    fi
  fi
  wait_for_postgres

  log_info "Starting maintenance upgrade containers (live web runner stays up until success)..."
  if ! run_schema_upgrades; then
    log_error "Automated schema upgrade aborted — live '${WEB_CONTAINER}' was NOT recycled."
    exit 1
  fi

  log_info "Maintenance upgrades clean — tearing down old web runner '${WEB_CONTAINER}'..."
  docker rm -f "${WEB_CONTAINER}" 2>/dev/null || true

  launch_web_container

  print_green_success "Core schema upgrade finished — cluster recycled on ${APP_IMAGE}"
  log_info "UI: http://localhost:${SOVIEZ_HOST_PORT}"
  log_info "    http://<your-server-ip>:${SOVIEZ_HOST_PORT}"
  log_info "Environment: ${ENV_FILE}"
  log_info "Security ledger: ${HOST_SOVIEZ_DIR}"
  exit 0
fi

# ===========================================================================
# MODE: new — provision next isolated multi-tenant instance
# ===========================================================================
if [[ "${MODE}" == "new" ]]; then
  mkdir -p "${INSTANCE_ROOT}"
  NEXT_INDEX="$(find_next_instance_index)"
  apply_topology_indexed "${NEXT_INDEX}"

  if [[ -f "${ENV_FILE}" ]]; then
    log_error "Target environment already exists: ${ENV_FILE}"
    exit 1
  fi

  log_info "Provisioning isolated multi-tenant instance index=${NEXT_INDEX}"
  log_info "Instance root: ${INSTANCE_ROOT}"
  log_info "Environment sheet: ${ENV_FILE}"
  log_info "Hunting free host TCP port from ${MULTI_PORT_START}..."

  SOVIEZ_CONTAINER_MAC="$(generate_mac)"
  SOVIEZ_DB_PASSWORD="$(generate_password)"
  SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
  SOVIEZ_HOST_PORT="$(find_free_host_port "${MULTI_PORT_START}")"

  cat > "${ENV_FILE}" <<EOF
SOVIEZ_INSTANCE_INDEX=${NEXT_INDEX}
SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}
SOVIEZ_CONTAINER_MAC=${SOVIEZ_CONTAINER_MAC}
SOVIEZ_DB_PASSWORD=${SOVIEZ_DB_PASSWORD}
SOVIEZ_ADMIN_PASSWORD=${SOVIEZ_ADMIN_PASSWORD}
SOVIEZ_NETWORK_NAME=${NETWORK_NAME}
SOVIEZ_DB_CONTAINER=${DB_CONTAINER}
SOVIEZ_WEB_CONTAINER=${WEB_CONTAINER}
SOVIEZ_DB_VOLUME=${DB_VOLUME}
SOVIEZ_FILESTORE_VOLUME=${FILESTORE_VOLUME}
EOF
  chmod 600 "${ENV_FILE}"

  log_info "Wrote ${ENV_FILE}"
  log_info "Assets: ${WEB_CONTAINER} / ${DB_CONTAINER} / ${NETWORK_NAME} / ${DB_VOLUME}"

  log_info "Pulling rolling images ${APP_IMAGE} + ${DB_IMAGE}..."
  docker pull "${APP_IMAGE}"
  docker pull "${DB_IMAGE}"

  ensure_network_and_volumes
  ensure_postgres_container

  if container_exists "${WEB_CONTAINER}"; then
    docker rm -f "${WEB_CONTAINER}" >/dev/null
  fi
  launch_web_container

  log_info "Isolated instance launch complete."
  log_info "UI: http://localhost:${SOVIEZ_HOST_PORT}"
  log_info "    http://<your-server-ip>:${SOVIEZ_HOST_PORT}"
  log_info "Environment locked at: ${ENV_FILE}"

  print_master_password_alert \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "INSTANCE #${NEXT_INDEX} — DATABASE MASTER PASSWORD (SAVE THIS NOW)"

  print_green_success "Multi-tenant instance #${NEXT_INDEX} provisioned on port ${SOVIEZ_HOST_PORT}"
  exit 0
fi

# ===========================================================================
# MODE: install — primary cluster bootstrap / relaunch
# ===========================================================================
apply_topology_primary
SHOW_ADMIN_PASSWORD_ALERT=0

if [[ -f "${ENV_FILE}" ]]; then
  log_info "Soviez ERP environment parameters already verified. Launching system cluster..."
  load_env_file

  NETWORK_NAME="${SOVIEZ_NETWORK_NAME:-${NETWORK_NAME}}"
  DB_CONTAINER="${SOVIEZ_DB_CONTAINER:-${DB_CONTAINER}}"
  WEB_CONTAINER="${SOVIEZ_WEB_CONTAINER:-${WEB_CONTAINER}}"
  DB_VOLUME="${SOVIEZ_DB_VOLUME:-${DB_VOLUME}}"
  FILESTORE_VOLUME="${SOVIEZ_FILESTORE_VOLUME:-${FILESTORE_VOLUME}}"

  if [[ -z "${SOVIEZ_HOST_PORT:-}" ]]; then
    log_info "Legacy environment detected — allocating persistent host port once..."
    SOVIEZ_HOST_PORT="$(find_free_host_port "${PRIMARY_PORT_START}")"
    persist_host_port "${SOVIEZ_HOST_PORT}"
    log_info "Locked SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT} into ${ENV_FILE}"
  else
    log_info "Reusing immutable host port SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}"
  fi

  if [[ -z "${SOVIEZ_ADMIN_PASSWORD:-}" ]]; then
    log_info "Legacy environment detected — generating Database Master Password once..."
    SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
    persist_env_key "SOVIEZ_ADMIN_PASSWORD" "${SOVIEZ_ADMIN_PASSWORD}"
    SHOW_ADMIN_PASSWORD_ALERT=1
    log_info "Locked SOVIEZ_ADMIN_PASSWORD into ${ENV_FILE}"
  fi
else
  # Write primary env into INSTANCE_ROOT when that is /root; else cwd.
  if [[ "${INSTANCE_ROOT}" == "/root" ]]; then
    ENV_FILE="${INSTANCE_ROOT}/.soviez.env"
  else
    ENV_FILE="$(pwd)/.soviez.env"
  fi

  log_info "First installation detected — generating immutable instance secrets..."
  log_info "Hunting for the first available host TCP port starting at ${PRIMARY_PORT_START}..."
  SOVIEZ_CONTAINER_MAC="$(generate_mac)"
  SOVIEZ_DB_PASSWORD="$(generate_password)"
  SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
  SOVIEZ_HOST_PORT="$(find_free_host_port "${PRIMARY_PORT_START}")"

  cat > "${ENV_FILE}" <<EOF
SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}
SOVIEZ_CONTAINER_MAC=${SOVIEZ_CONTAINER_MAC}
SOVIEZ_DB_PASSWORD=${SOVIEZ_DB_PASSWORD}
SOVIEZ_ADMIN_PASSWORD=${SOVIEZ_ADMIN_PASSWORD}
SOVIEZ_NETWORK_NAME=${NETWORK_NAME}
SOVIEZ_DB_CONTAINER=${DB_CONTAINER}
SOVIEZ_WEB_CONTAINER=${WEB_CONTAINER}
SOVIEZ_DB_VOLUME=${DB_VOLUME}
SOVIEZ_FILESTORE_VOLUME=${FILESTORE_VOLUME}
EOF
  chmod 600 "${ENV_FILE}"
  SHOW_ADMIN_PASSWORD_ALERT=1

  log_info "Wrote ${ENV_FILE}"
  log_info "SOVIEZ_CONTAINER_MAC=${SOVIEZ_CONTAINER_MAC}"
  log_info "SOVIEZ_DB_PASSWORD=(32-character token redacted)"
  log_info "SOVIEZ_ADMIN_PASSWORD=(32-character token — shown in red alert below)"
  log_info "SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}"
fi

require_complete_env

ensure_network_and_volumes

log_info "Pulling rolling images ${APP_IMAGE} + ${DB_IMAGE}..."
docker pull "${APP_IMAGE}"
docker pull "${DB_IMAGE}"

ensure_postgres_container

if container_exists "${WEB_CONTAINER}"; then
  log_info "Removing previous application container '${WEB_CONTAINER}' for clean recreate..."
  docker rm -f "${WEB_CONTAINER}" >/dev/null
fi

launch_web_container

log_info "Cluster launch complete."
log_info "UI: http://localhost:${SOVIEZ_HOST_PORT}"
log_info "    http://<your-server-ip>:${SOVIEZ_HOST_PORT}"
log_info "First boot: open the URL to use the interactive Web Database Manager."
log_info "Environment locked at: ${ENV_FILE}"
log_info "Images: ${APP_IMAGE} | ${DB_IMAGE}"

if (( SHOW_ADMIN_PASSWORD_ALERT == 1 )); then
  print_master_password_alert \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "DATABASE MASTER PASSWORD (SAVE THIS NOW)"
fi
