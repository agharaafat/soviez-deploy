# Soviez ERP (v18.0.1.01.0)

**A hardened, high-performance, corporate-sovereign Enterprise Resource Planning platform.**

Soviez ERP is a specialized, production-ready **fork of Odoo 18**, engineered for total data privacy, infrastructure independence, and zero vendor lock-in. Deploy it on your metal, in your VPC, or on any Docker-capable host — you retain full control of the runtime, the database, and the data plane.

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

## Instant Setup

On any Docker Engine 24+ host, run the public bootstrap wrapper:

```bash
curl -fsSL https://raw.githubusercontent.com/agharaafat/soviez-deploy/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```

The installer:

- Creates an immutable `.soviez.env` (container network identity, database password, dynamic host port from **8069** upward)
- Starts PostgreSQL with `POSTGRES_DB=postgres` only (no empty application schema)
- Starts `soviez/soviez-erp:v18.0.1.01.0` **without** `POSTGRES_DB`, so Odoo does not bind to a broken empty database
- Prints the bound UI URL (for example `http://localhost:8071` when 8069 is already in use)

### Access

| Surface | Endpoint |
|---------|----------|
| **Web UI** | `http://<your-server-ip>:${SOVIEZ_HOST_PORT}` |
| **Image** | [`soviez/soviez-erp:v18.0.1.01.0`](https://hub.docker.com/r/soviez/soviez-erp) |

**First boot:** navigate to the printed URL. Soviez ERP opens the interactive **Web Database Manager** so you can create a fresh database. After initialization, apply your perpetual activation key and proceed to Apps.

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
  postgres:15-alpine

# Soviez ERP — authenticate to the cluster; omit POSTGRES_DB entirely
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
  soviez/soviez-erp:v18.0.1.01.0 \
  python3 soviez-bin -c soviez.conf \
    --db_host=soviez-db \
    --db_port=5432 \
    --db_user=soviez \
    --db_password="${SOVIEZ_DB_PASSWORD}" \
    --data-dir=/root/.local/share/Odoo
```

---

## Support

- Product documentation: [https://soviez.com/docs](https://soviez.com/docs)
- Commercial inquiries: [sales@soviez.com](mailto:sales@soviez.com)
- Security: [support@soviez.com](mailto:support@soviez.com)

---

© 2026 Soviez ERP Contributors — Sovereign. Private. Production-ready.
