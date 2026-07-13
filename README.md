# Soviez ERP (v18.0.1.01.0)

**A hardened, high-performance, corporate-sovereign Enterprise Resource Planning platform.**

Soviez ERP is a specialized, production-ready **sovereign enterprise resource planning platform**, engineered for total data privacy, infrastructure independence, and zero vendor lock-in. Deploy it on your metal, in your VPC, or on any Docker-capable host — you retain full control of the runtime, the database, and the data plane.

[![Version](https://img.shields.io/badge/version-18.0.1.01.0-0D9488.svg)](https://hub.docker.com/r/soviez/soviez-erp)
[![Docker](https://img.shields.io/badge/docker-soviez%2Fsoviez--erp-2496ED.svg)](https://hub.docker.com/r/soviez/soviez-erp)
[![License](https://img.shields.io/badge/license-LGPL--3-111827.svg)](https://soviez.com)

---

## The Perpetual Model

Soviez ERP is licensed for **financial freedom**, not subscription captivity:

| Principle | What you get |
|-----------|----------------|
| **Single-instance activation** | One activation key unlocks **one database instance for life** |
| **Zero seat taxes** | **No** monthly per-user fees, tier traps, or hidden “enterprise packs” |
| **Full infrastructure control** | Self-hosted topology — no mandatory cloud phone-homes |
| **Predictable TCO** | CapEx-friendly perpetual model aligned with corporate IT budgeting |

Your instance stays yours — commercially and operationally.

---

## How to Get a License

Enterprise teams obtain a unique activation key bound to their hardware deployment signature through the Soviez commercial channel:

1. **Sales desk:** [sales@soviez.com](mailto:sales@soviez.com)  
2. **Pricing & plans:** [https://soviez.com/pricing](https://soviez.com/pricing)

Include your intended deployment region and approximate user scale so we can issue the correct perpetual activation package for your node.

---

## 🎛️ Production System Requirements

### 1. Hardware Minimum Specifications

- **CPU**: 2 vCPUs minimum (4 vCPUs recommended for >20 concurrent users).
- **RAM**: 4 GB RAM baseline + 2 GB Swap space minimum.
- **Storage**: 20 GB SSD/NVMe free space (excluding OS and filestore growth).
- **OS**: Linux (Ubuntu 22.04/24.04 LTS or Debian 11/12 recommended) with Docker Engine installed.

### 🔒 2. Mandatory SSL & Reverse Proxy Infrastructure

Because Soviez ERP operates on a strict, hardened secure cookie architecture (`secure=True`, `HttpOnly`, `SameSite=Lax`), **the system WILL NOT retain login sessions over unencrypted HTTP or raw IP connections.**

> **Critical:** Deploying against plain `http://` or a bare IP address will appear to “log in” and then immediately drop the session. Production traffic **must** terminate TLS at a reverse proxy before reaching the application container.

- **Domain Name**: A valid fully qualified domain name (FQDN) is highly recommended.
- **Reverse Proxy**: You **MUST** deploy the container behind a Reverse Proxy (such as Nginx, Traefik, or Apache) acting as a TLS terminator.
- **SSL Certificate**: A valid SSL/TLS certificate (e.g., via Let's Encrypt / Certbot) must be installed on the reverse proxy to encapsulate all traffic.

### 🔑 3. Commercial Licensing

Soviez ERP is a locked commercial platform. Running this stack requires a valid, instance-bound (MAC::UUID) license signature.

- To procure or renew a valid instance key, visit the official pricing console at: [soviez.com/pricing](https://soviez.com/pricing).
- Unlicensed instances will fail-closed and restrict backend workflow operations until a cryptographically verified signature is bound via the software activation assistant.

---

## Instant Setup

On any Docker Engine 24+ host, run the public bootstrap wrapper:

```bash
curl -fsSL https://raw.githubusercontent.com/agharaafat/soviez-deploy/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```

The installer:

- Creates an immutable `.soviez.env` (container network identity, Postgres password, **Database Master Password**, dynamic host port from **8069** upward)
- Starts PostgreSQL (`postgres:latest`) with `POSTGRES_DB=postgres` only (no empty application schema)
- Starts **`soviez/soviez-erp:latest`** **without** `POSTGRES_DB`, injecting `--admin-passwd` from `SOVIEZ_ADMIN_PASSWORD`
- Prints the bound UI URL (for example `http://localhost:8071` when 8069 is already in use)
- Prints a high-visibility **red console alert** with the Database Master Password on first install — save it immediately

### Access

| Surface | Endpoint |
|---------|----------|
| **Web UI** | `http://<your-server-ip>:${SOVIEZ_HOST_PORT}` |
| **Image** | [`soviez/soviez-erp:latest`](https://hub.docker.com/r/soviez/soviez-erp) |

**First boot:** navigate to the printed URL. Soviez ERP opens the interactive **Web Database Manager**. Enter the Master Password from the red alert (or `SOVIEZ_ADMIN_PASSWORD` in `.soviez.env`) to create a fresh database. After initialization, apply your perpetual activation key and proceed to Apps.

### 🔑 Database Master Password Reset & Recovery

Lost the Master Password? Rotate it without touching databases or volumes:

```bash
./setup.sh --recoverdbpass
```

This injects a fresh secure master key into `.soviez.env`, recycles only the `soviez-web` container, and displays the new token in a red console alert. Existing database configurations and Docker volumes are preserved.

### 🔄 Upgrading Application Containers & Database Schema

Track rolling Hub releases and migrate schemas in one command:

```bash
./setup.sh --update
```

Pulls `soviez/soviez-erp:latest` + `postgres:latest`, runs `-u base,local_license_guard,mail,web,web_enterprise,soviez_web_ui --stop-after-init` against discovered databases, recycles `soviez-web`, and prints a green success banner. Volumes, MAC/port secrets, and existing license bindings stay intact — `--update` upgrades the runtime and schema without requiring re-activation.

### 🏢 Provisioning Multi-Tenant Isolated Instances

Spin infinite parallel ERP clusters on one host:

```bash
./setup.sh --new
```

Allocates the next index (`.soviez_1.env`, `.soviez_2.env`, … under `/root` when writable), creates sandboxed network/volume/container names, binds a free port from **8073** upward, generates unique secrets + MAC, and flashes the new Master Password in a red alert.

### Manual `docker run` (equivalent topology)

```bash
# PostgreSQL — maintenance DB only (do not pre-create an empty "soviez" schema)
docker run -d \
  --name soviez-db \
  --restart unless-stopped \
  --network soviez_network \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_USER=soviez \
  -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
  -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
  -v soviez_db_data:/var/lib/postgresql/data \
  postgres:latest

# Soviez ERP — authenticate to the cluster; omit POSTGRES_DB; inject master password
docker run -d \
  --name soviez-web \
  --restart unless-stopped \
  --network soviez_network \
  --mac-address "${SOVIEZ_CONTAINER_MAC}" \
  -p "${SOVIEZ_HOST_PORT}:8069" \
  -e POSTGRES_USER=soviez \
  -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
  -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
  -v soviez_filestore:/root/.local/share/Odoo/filestore \
  soviez/soviez-erp:latest \
  python3 soviez-bin -c soviez.conf \
    --db_host=soviez-db \
    --db_port=5432 \
    --db_user=soviez \
    --db_password="${SOVIEZ_DB_PASSWORD}" \
    --data-dir=/root/.local/share/Odoo \
    --admin-passwd="${SOVIEZ_ADMIN_PASSWORD}"
```

---

## Support

- Product documentation: [https://soviez.com/docs](https://soviez.com/docs)
- Commercial inquiries: [sales@soviez.com](mailto:sales@soviez.com)
- Security: [support@soviez.com](mailto:support@soviez.com)

---

© 2026 Soviez ERP Contributors — Sovereign. Private. Production-ready.
