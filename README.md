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
- Starts PostgreSQL and the `soviez/soviez-erp:v18.0.1.01.0` application stack
- Prints the bound UI URL (for example `http://localhost:8071` when 8069 is already in use)

### Access

| Surface | Endpoint |
|---------|----------|
| **Web UI** | `http://<your-server-ip>:${SOVIEZ_HOST_PORT}` |
| **Image** | [`soviez/soviez-erp:v18.0.1.01.0`](https://hub.docker.com/r/soviez/soviez-erp) |

After first boot, open the database manager, apply your perpetual activation key, and proceed to Apps.

---

## Support

- Product documentation: [https://soviez.com/docs](https://soviez.com/docs)
- Commercial inquiries: [sales@soviez.com](mailto:sales@soviez.com)
- Security: [support@soviez.com](mailto:support@soviez.com)

---

© 2026 Soviez ERP Contributors — Sovereign. Private. Production-ready.
