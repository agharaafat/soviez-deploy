#!/usr/bin/env bash
# Soviez ERP — zero-dependency bootstrap (empty-directory safe)
# Uses pure `docker run` only — no docker-compose.yml or host config mounts required.
#
# Usage:
#   ./setup.sh                 # install / relaunch cluster
#   ./setup.sh --recoverdbpass # rotate Database Master Password + recycle web
set -euo pipefail

readonly IMAGE_TAG="soviez/soviez-erp:v18.0.1.01.0"
readonly NETWORK_NAME="soviez_network"
readonly DB_CONTAINER="soviez-db"
readonly WEB_CONTAINER="soviez-web"
readonly DB_VOLUME="soviez_db_data"
readonly FILESTORE_VOLUME="soviez_filestore"
readonly ENV_FILE=".soviez.env"
readonly PORT_SCAN_START=8069
readonly PORT_SCAN_MAX=8999

# ---------------------------------------------------------------------------
# Argument parser (absolute top — before any side effects beyond mode select)
# ---------------------------------------------------------------------------
RECOVER_DB_PASS=0
for arg in "$@"; do
  case "${arg}" in
    --recoverdbpass)
      RECOVER_DB_PASS=1
      ;;
    -h|--help)
      cat <<'USAGE'
Soviez ERP bootstrap

Usage:
  ./setup.sh                 Install or relaunch the Docker cluster
  ./setup.sh --recoverdbpass Rotate Database Master Password and recycle soviez-web
  ./setup.sh --help          Show this help
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

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_error "Required command not found: $1"
    exit 1
  fi
}

require_cmd docker
require_cmd python3

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
  local port="${PORT_SCAN_START}"
  while (( port <= PORT_SCAN_MAX )); do
    if is_port_busy "${port}"; then
      log_warn "Port ${port} is busy, probing next system socket..."
      port=$((port + 1))
    else
      echo "${port}"
      return 0
    fi
  done
  log_error "No free TCP port available in range ${PORT_SCAN_START}-${PORT_SCAN_MAX}."
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

launch_web_container() {
  log_info "Launching Soviez ERP (${WEB_CONTAINER})..."
  log_info "Host publish map: ${SOVIEZ_HOST_PORT} → container 8069"
  log_info "Pinned MAC address: ${SOVIEZ_CONTAINER_MAC}"

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
    "${IMAGE_TAG}" \
    python3 soviez-bin -c soviez.conf \
      --db_host=soviez-db \
      --db_port=5432 \
      --db_user=soviez \
      --db_password="${SOVIEZ_DB_PASSWORD}" \
      --data-dir=/root/.local/share/Odoo \
      --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}" >/dev/null
}

ensure_network_and_volumes() {
  log_info "Ensuring private bridge network '${NETWORK_NAME}'..."
  docker network create "${NETWORK_NAME}" 2>/dev/null || true

  log_info "Ensuring persistent volumes..."
  docker volume create "${DB_VOLUME}" >/dev/null
  docker volume create "${FILESTORE_VOLUME}" >/dev/null
}

# ---------------------------------------------------------------------------
# Recovery path — rotate master password, recycle web only, exit early
# ---------------------------------------------------------------------------
if (( RECOVER_DB_PASS == 1 )); then
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

  log_info "Pulling application image ${IMAGE_TAG}..."
  docker pull "${IMAGE_TAG}"

  launch_web_container

  print_master_password_alert \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "MASTER PASSWORD RESET — APPLICATION LAYER RECYCLED"

  log_info "Master Password successfully reset. Existing databases and volumes were preserved."
  log_info "UI: http://localhost:${SOVIEZ_HOST_PORT}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1) Pristine environment generation / load
# ---------------------------------------------------------------------------
SHOW_ADMIN_PASSWORD_ALERT=0

if [[ -f "${ENV_FILE}" ]]; then
  log_info "Soviez ERP environment parameters already verified. Launching system cluster..."
  load_env_file

  if [[ -z "${SOVIEZ_HOST_PORT:-}" ]]; then
    log_info "Legacy environment detected — allocating persistent host port once..."
    SOVIEZ_HOST_PORT="$(find_free_host_port)"
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
  log_info "First installation detected — generating immutable instance secrets..."
  log_info "Hunting for the first available host TCP port starting at ${PORT_SCAN_START}..."
  SOVIEZ_CONTAINER_MAC="$(generate_mac)"
  SOVIEZ_DB_PASSWORD="$(generate_password)"
  SOVIEZ_ADMIN_PASSWORD="$(generate_password)"
  SOVIEZ_HOST_PORT="$(find_free_host_port)"

  cat > "${ENV_FILE}" <<EOF
SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}
SOVIEZ_CONTAINER_MAC=${SOVIEZ_CONTAINER_MAC}
SOVIEZ_DB_PASSWORD=${SOVIEZ_DB_PASSWORD}
SOVIEZ_ADMIN_PASSWORD=${SOVIEZ_ADMIN_PASSWORD}
EOF
  chmod 600 "${ENV_FILE}"
  SHOW_ADMIN_PASSWORD_ALERT=1

  log_info "Wrote ${ENV_FILE}"
  log_info "SOVIEZ_CONTAINER_MAC=${SOVIEZ_CONTAINER_MAC}"
  log_info "SOVIEZ_DB_PASSWORD=(32-character token redacted)"
  log_info "SOVIEZ_ADMIN_PASSWORD=(32-character token — shown in red alert below)"
  log_info "SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}"
fi

if [[ -z "${SOVIEZ_CONTAINER_MAC:-}" || -z "${SOVIEZ_DB_PASSWORD:-}" || -z "${SOVIEZ_HOST_PORT:-}" || -z "${SOVIEZ_ADMIN_PASSWORD:-}" ]]; then
  log_error "${ENV_FILE} is missing SOVIEZ_CONTAINER_MAC, SOVIEZ_DB_PASSWORD, SOVIEZ_ADMIN_PASSWORD, or SOVIEZ_HOST_PORT."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2) Infrastructure assembly
# ---------------------------------------------------------------------------
ensure_network_and_volumes

# ---------------------------------------------------------------------------
# 3) Database container launch
# ---------------------------------------------------------------------------
if container_running "${DB_CONTAINER}"; then
  log_info "Database container '${DB_CONTAINER}' already running — leaving it in place."
elif container_exists "${DB_CONTAINER}"; then
  log_info "Starting existing database container '${DB_CONTAINER}'..."
  docker start "${DB_CONTAINER}" >/dev/null
else
  log_info "Launching PostgreSQL (${DB_CONTAINER}) on ${NETWORK_NAME}..."
  # POSTGRES_DB=postgres: do NOT pre-create an empty application schema.
  # An empty named DB (e.g. soviez) makes Odoo treat it as an instance and
  # crash with KeyError: 'ir.http'. Operators create DBs via the Web Manager.
  docker run -d \
    --name "${DB_CONTAINER}" \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    -e POSTGRES_DB=postgres \
    -e POSTGRES_USER=soviez \
    -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
    -v "${DB_VOLUME}:/var/lib/postgresql/data" \
    postgres:15-alpine >/dev/null
fi

log_info "Waiting for PostgreSQL readiness..."
for _ in $(seq 1 30); do
  if docker exec "${DB_CONTAINER}" pg_isready -U soviez -d postgres >/dev/null 2>&1; then
    log_info "PostgreSQL is ready."
    break
  fi
  sleep 1
done
if ! docker exec "${DB_CONTAINER}" pg_isready -U soviez -d postgres >/dev/null 2>&1; then
  log_error "PostgreSQL did not become ready in time. Inspect: docker logs ${DB_CONTAINER}"
  exit 1
fi

# ---------------------------------------------------------------------------
# 4) Application container launch
# ---------------------------------------------------------------------------
log_info "Pulling application image ${IMAGE_TAG}..."
docker pull "${IMAGE_TAG}"

if container_exists "${WEB_CONTAINER}"; then
  log_info "Removing previous application container '${WEB_CONTAINER}' for clean recreate..."
  docker rm -f "${WEB_CONTAINER}" >/dev/null
fi

launch_web_container

log_info "Cluster launch complete."
log_info "UI: http://localhost:${SOVIEZ_HOST_PORT}"
log_info "    http://<your-server-ip>:${SOVIEZ_HOST_PORT}"
log_info "First boot: open the URL to use the interactive Web Database Manager."
log_info "Environment locked at: $(pwd)/${ENV_FILE}"

if (( SHOW_ADMIN_PASSWORD_ALERT == 1 )); then
  print_master_password_alert \
    "${SOVIEZ_ADMIN_PASSWORD}" \
    "DATABASE MASTER PASSWORD (SAVE THIS NOW)"
fi
