#!/usr/bin/env bash
# Soviez ERP — first-boot environment provisioning + cluster launch
# Generates immutable MAC, DB password, and host port; preserves them forever after.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the compose project (supports running from workspace root or app root).
if [[ -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
  APP_DIR="${SCRIPT_DIR}"
elif [[ -f "${SCRIPT_DIR}/Soviez ERP/docker-compose.yml" ]]; then
  APP_DIR="${SCRIPT_DIR}/Soviez ERP"
else
  echo "[ERROR] Unable to locate Soviez ERP docker-compose.yml near ${SCRIPT_DIR}" >&2
  exit 1
fi

cd "${APP_DIR}"
umask 077

# Prefer .soviez.env (documented); fall back to legacy .env for continuity.
if [[ -f "${APP_DIR}/.soviez.env" ]]; then
  ENV_FILE="${APP_DIR}/.soviez.env"
elif [[ -f "${APP_DIR}/.env" ]]; then
  ENV_FILE="${APP_DIR}/.env"
else
  ENV_FILE="${APP_DIR}/.soviez.env"
fi

readonly PORT_SCAN_START=8069
readonly PORT_SCAN_MAX=8999

# ---------------------------------------------------------------------------
# Port occupancy probe — ss → netstat → bash /dev/tcp
# Returns 0 when the TCP port is busy (in use), 1 when free.
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

  # Bash TCP probe: connect success ⇒ listener present ⇒ busy.
  if (echo >/dev/tcp/127.0.0.1/"${port}") >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Scan upward from 8069 until a free host socket is found.
find_free_host_port() {
  local port="${PORT_SCAN_START}"
  while (( port <= PORT_SCAN_MAX )); do
    if is_port_busy "${port}"; then
      echo "[WARN] Port ${port} is busy, probing next system socket..." >&2
      port=$((port + 1))
    else
      echo "${port}"
      return 0
    fi
  done
  echo "[ERROR] No free TCP port available in range ${PORT_SCAN_START}-${PORT_SCAN_MAX}." >&2
  return 1
}

generate_mac() {
  # Locally administered unicast MAC — fixed OUI prefix 02:42:ac + 3 random octets.
  python3 - <<'PY'
import secrets
octets = [secrets.randbelow(256) for _ in range(3)]
print("02:42:ac:" + ":".join(f"{b:02x}" for b in octets))
PY
}

generate_password() {
  # 32-character alphanumeric token (cryptographically strong).
  python3 - <<'PY'
import secrets
import string
alphabet = string.ascii_letters + string.digits
print("".join(secrets.choice(alphabet) for _ in range(32)))
PY
}

persist_host_port() {
  local port="$1"
  if grep -q '^SOVIEZ_HOST_PORT=' "${ENV_FILE}" 2>/dev/null; then
    # Portable in-place update without relying on GNU sed -i.
    local tmp
    tmp="$(mktemp)"
    grep -v '^SOVIEZ_HOST_PORT=' "${ENV_FILE}" > "${tmp}"
    echo "SOVIEZ_HOST_PORT=${port}" >> "${tmp}"
    mv "${tmp}" "${ENV_FILE}"
  else
    echo "SOVIEZ_HOST_PORT=${port}" >> "${ENV_FILE}"
  fi
  chmod 600 "${ENV_FILE}"
}

# ---------------------------------------------------------------------------
# Environment bootstrap
# ---------------------------------------------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
  echo "[INFO] Soviez ERP environment parameters already verified. Launching system cluster..."
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a

  if [[ -z "${SOVIEZ_HOST_PORT:-}" ]]; then
    echo "[INFO] Legacy environment detected — allocating persistent host port once..."
    SOVIEZ_HOST_PORT="$(find_free_host_port)"
    persist_host_port "${SOVIEZ_HOST_PORT}"
    echo "[INFO] Locked SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT} into ${ENV_FILE}"
  else
    echo "[INFO] Reusing immutable host port SOVIEZ_HOST_PORT=${SOVIEZ_HOST_PORT}"
  fi
else
  echo "[INFO] First installation detected — generating immutable instance secrets..."
  MAC_ADDR="$(generate_mac)"
  DB_PASSWORD="$(generate_password)"
  echo "[INFO] Hunting for the first available host TCP port starting at ${PORT_SCAN_START}..."
  HOST_PORT="$(find_free_host_port)"

  cat > "${ENV_FILE}" <<EOF
SOVIEZ_CONTAINER_MAC=${MAC_ADDR}
SOVIEZ_DB_PASSWORD=${DB_PASSWORD}
SOVIEZ_HOST_PORT=${HOST_PORT}
EOF
  chmod 600 "${ENV_FILE}"

  # Keep a compose-compatible .env sibling when using .soviez.env
  if [[ "$(basename "${ENV_FILE}")" == ".soviez.env" ]]; then
    cp -f "${ENV_FILE}" "${APP_DIR}/.env"
    chmod 600 "${APP_DIR}/.env"
  fi

  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a

  echo "[INFO] Wrote ${ENV_FILE}"
  echo "[INFO] SOVIEZ_CONTAINER_MAC=${MAC_ADDR}"
  echo "[INFO] SOVIEZ_DB_PASSWORD=(32-character token redacted)"
  echo "[INFO] SOVIEZ_HOST_PORT=${HOST_PORT}"
fi

# Safety: refuse to start without required keys.
if [[ -z "${SOVIEZ_CONTAINER_MAC:-}" || -z "${SOVIEZ_DB_PASSWORD:-}" || -z "${SOVIEZ_HOST_PORT:-}" ]]; then
  echo "[ERROR] Environment is missing SOVIEZ_CONTAINER_MAC, SOVIEZ_DB_PASSWORD, or SOVIEZ_HOST_PORT." >&2
  exit 1
fi

# Ensure compose can see the same variables (docker compose loads .env by default).
if [[ "$(basename "${ENV_FILE}")" == ".soviez.env" ]]; then
  cp -f "${ENV_FILE}" "${APP_DIR}/.env"
  chmod 600 "${APP_DIR}/.env"
fi

echo "[INFO] Building and starting Soviez ERP containers..."
echo "[INFO] Host publish map: ${SOVIEZ_HOST_PORT} → container 8069"
docker compose --env-file "${ENV_FILE}" up -d --build

echo "[INFO] Cluster launch requested."
echo "[INFO] UI: http://localhost:${SOVIEZ_HOST_PORT}"
echo "[INFO]     http://<your-server-ip>:${SOVIEZ_HOST_PORT}"
