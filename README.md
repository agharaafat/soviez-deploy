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
- **OS**: Linux (**Ubuntu 22.04/24.04 LTS** or **Debian 11/12** recommended). Root / sudo required for the official installer.

### 🔒 2. Mandatory SSL & Reverse Proxy Infrastructure

Because Soviez ERP operates on a strict, hardened secure cookie architecture (`secure=True`, `HttpOnly`, `SameSite=Lax`), **the system WILL NOT retain login sessions over unencrypted HTTP or raw IP connections.**

> **Critical:** Deploying against plain `http://` or a bare IP address will appear to “log in” and then immediately drop the session. Production traffic **must** terminate TLS at a reverse proxy before reaching the application container.

The official installer configures **Nginx + HTTPS** when you provision a tenant with `./soviez.sh --new`. You need a domain whose DNS points at your server.

The wizard always binds **port 443** immediately (self-signed baseline), then upgrades to Let's Encrypt when Certbot can reach the host. If Certbot fails (common with Cloudflare proxied 🟠 records), HTTPS stays online on the self-signed cert — set Cloudflare SSL/TLS to **Full**. Repair later with `./soviez.sh --formssl`.

- **Domain Name**: A valid FQDN is required for production HTTPS sessions.
- **Reverse Proxy / SSL**: Handled by the wizard (Nginx + Certbot / self-signed fallback), or any equivalent TLS terminator you operate.

### 🔑 3. Commercial Licensing

Soviez ERP is a locked commercial platform. Running this stack requires a valid, instance-bound (MAC::UUID) license signature.

- To procure or renew a valid instance key, visit the official pricing console at: [soviez.com/pricing](https://soviez.com/pricing).
- Unlicensed instances will fail-closed and restrict backend workflow operations until a cryptographically verified signature is bound via the software activation assistant.

---

## Instant Setup

On Ubuntu/Debian, download the public bootstrap wizard and run the **two-step** production flow:

```bash
curl -fsSL https://raw.githubusercontent.com/agharaafat/soviez-deploy/main/soviez.sh -o soviez.sh
chmod +x soviez.sh

# 1) Prepare the host (Docker, Nginx, Certbot, firewall) — no ERP containers yet
sudo ./soviez.sh --init

# 2) Point your domain’s DNS A/AAAA record at this server, then provision the live tenant
sudo ./soviez.sh --new

# 2b) If provisioning failed mid-flight on Nginx/SSL, heal and resume:
sudo ./soviez.sh --formsetup

# 2c) HTTPS-only repair (Cloudflare / Let's Encrypt retry):
sudo ./soviez.sh --formssl
```

| Mode | Command | Role |
|------|---------|------|
| **Init** | `./soviez.sh --init` (default) | Apt, Docker, Nginx, Certbot, UFW — host only |
| **New** | `./soviez.sh --new` | Domain + DNS check + isolated ERP/Postgres stack + HTTPS |
| **Form setup** | `./soviez.sh --formsetup` | Resume / heal the latest half-configured tenant (idempotent) |
| **Form SSL** | `./soviez.sh --formssl [domain]` | Diagnose / repair HTTPS (Let's Encrypt or self-signed) |
| **Update** | `./soviez.sh --update` | Pull latest ERP image and upgrade schemas |
| **Recover** | `./soviez.sh --recoverdbpass` | Rotate Database Master Password |

The installer:

- Keeps verbose detail in **`/var/log/soviez_setup.log`**; the terminal shows clean status lines only
- On `--new`: creates an immutable `.soviez_N.env` (MAC, Postgres password, **Database Master Password**, host port from **8073**), starts **`postgres:16`** + **`soviez/soviez-erp:latest`**, mounts custom addons under `/etc/soviez_web_N/addons`, writes Nginx `:80` + `:443` (self-signed baseline → Certbot), and prints the live **`https://your.domain`** URL
- Flashes a high-visibility console alert with the Database Master Password — save it immediately
- If Let's Encrypt fails, keeps self-signed HTTPS online and reminds you to set Cloudflare SSL/TLS to **Full**

Images:

| Image | Tag |
|-------|-----|
| Application | `soviez/soviez-erp:latest` (rolling) |
| Database | **`postgres:16`** (pinned for stability) |

### Access

| Surface | Endpoint |
|---------|----------|
| **Web UI** | `https://<your-domain>` after `--new` |
| **Image** | [`soviez/soviez-erp:latest`](https://hub.docker.com/r/soviez/soviez-erp) |

**First boot:** open the HTTPS URL. Soviez ERP opens the interactive **Web Database Manager**. Enter the Master Password from the console alert (or `SOVIEZ_ADMIN_PASSWORD` in the tenant env sheet) to create a fresh database. After initialization, apply your perpetual activation key and proceed to Apps.

### 🔑 Database Master Password Reset & Recovery

Lost the Master Password? Rotate it without touching databases or volumes:

```bash
sudo ./soviez.sh --recoverdbpass
```

This injects a fresh secure master key into the env sheet, recycles only the web container, and displays the new token. Existing databases and Docker volumes are preserved.

### 🔄 Upgrading Application Containers & Database Schema

Track Hub ERP releases and migrate schemas in one command:

```bash
sudo ./soviez.sh --update
```

Pulls **`soviez/soviez-erp:latest`**, bind-mounts `~/.soviez` (mode 700), **stops web runners first** to release DB locks, upgrades every discovered database with `-u base,local_license_guard,mail,web,web_enterprise,soviez_web_ui --stop-after-init`, purges compiled `/web/assets/*` attachments, then relaunches web containers. Postgres stays on **`postgres:16`**. Volumes, MAC/port secrets, ledger tokens, and license bindings stay intact — no re-activation required for a normal upgrade.

### 🏢 Provisioning Multi-Tenant Isolated Instances

Spin parallel ERP clusters on one host:

```bash
sudo ./soviez.sh --new
```

Each run allocates the next index (`.soviez_1.env`, `.soviez_2.env`, …), creates sandboxed network/volume/container names, prepares `/etc/soviez_web_N/addons`, binds a free port from **8073**, validates DNS for your domain, issues TLS, and flashes the new Master Password.

### 🩹 Form Setup — Resume a Failed Provision

If `--new` stopped after writing secrets/containers but before HTTPS was fully online:

```bash
sudo ./soviez.sh --formsetup
```

Resumes the latest half-configured tenant idempotently (keeps volumes, starts stopped containers, rewrites Nginx + HTTPS, reprints the welcome banner and Master Password). Safe to re-run.

### 🔐 Form SSL — Fix HTTPS (Cloudflare / Let's Encrypt)

```bash
sudo ./soviez.sh --formssl
sudo ./soviez.sh --formssl erp.example.com
```

Diagnoses the tenant vhost, retries Let's Encrypt, and if Certbot still fails keeps a self-signed `:443` cert so the site stays reachable with Cloudflare SSL set to **Full**. Never leaves the domain on HTTP-only (which lets other host panels capture HTTPS).

### Manual `docker run` (lab / equivalent topology)

Prefer the wizard for production HTTPS. For a minimal manual mirror:

```bash
# PostgreSQL — pinned 16.x; maintenance DB only (do not pre-create an empty app schema)
docker run -d \
  --name soviez-db \
  --restart unless-stopped \
  --network soviez_network \
  -e POSTGRES_DB=postgres \
  -e POSTGRES_USER=soviez \
  -e POSTGRES_PASSWORD="${SOVIEZ_DB_PASSWORD}" \
  -e PASSWORD="${SOVIEZ_DB_PASSWORD}" \
  -v soviez_db_data:/var/lib/postgresql/data \
  postgres:16

# Soviez ERP — omit POSTGRES_DB; inject master password; terminate TLS in front
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
  -v "${HOME}/.soviez:/root/.soviez" \
  soviez/soviez-erp:latest \
  python3 soviez-bin -c /opt/soviez-erp/soviez.conf \
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
