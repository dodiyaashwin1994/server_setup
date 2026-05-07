# 🚀 SaaS Infrastructure Foundation (Traefik Edition)

A centralized, containerized infrastructure for multi-tenant SaaS deployment, featuring **Traefik v3.1**, automated **Wildcard SSL**, and managed service stacks.

## 🏗️ Architecture Overview

- **Reverse Proxy**: **Traefik** acting as the primary ingress with automatic service discovery.
- **SSL Management**: Native Traefik ACME with Cloudflare DNS-01 challenge for **Wildcard SSL** (`*.yourdomain.com`).
- **Core Services**: 
  - **Redis**: Mandatory caching layer (isolated by DB index per service).
  - **MySQL**: Master database container.
  - **RabbitMQ**: Shared message broker with management UI.
- **Routing Model**: Label-based. Each service "announces" its subdomain and port via Docker labels.

---

## 🛠️ Getting Started

### 1. Prerequisites
- A fresh Ubuntu server.
- **Cloudflare DNS**: API Token with DNS Edit permissions.
- **GitHub Secrets**:
  - `SERVER_HOST`: Your server IP.
  - `SERVER_USER`: Deployment user (e.g., `root`).
  - `BOOTSTRAP_SSH_PRIVATE_KEY_BASE64`: Your server's SSH private key.
  - `CF_DNS_API_TOKEN`: Cloudflare credential.
  - `TRAEFIK_DASHBOARD_AUTH`: Hashed credentials for the dashboard (`user:hashedpass`).

### 2. Deployment
Trigger the **"Setup And Deploy Infra"** workflow from the Actions tab. It will:
1. Bootstrap the server (Docker, Networks, UFW).
2. Start the Traefik Hub.
3. Provision MySQL, Redis, and RabbitMQ.

---

## 📂 Service Integration

To add a new service to the infrastructure, simply add these labels to your service's `docker-compose.yml`:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.${SERVICE_NAME}.rule=Host(`${SERVICE_NAME}.${SERVICE_DOMAIN}`)"
  - "traefik.http.routers.${SERVICE_NAME}.entrypoints=websecure"
  - "traefik.http.routers.${SERVICE_NAME}.tls=true"
  - "traefik.http.routers.${SERVICE_NAME}.tls.certresolver=cloudflare"
  - "traefik.http.services.${SERVICE_NAME}.loadbalancer.server.port=8000"
```

---

## 📊 Management Dashboards

- **Traefik Dashboard**: `https://traefik.autoleaze.com`
- **RabbitMQ Management**: `https://rabbitmq.autoleaze.com`

---

## 🔐 Database Access

MySQL and Redis are exposed for management from your local host:
- **MySQL Port**: `3306`
- **Redis Port**: `6379`
