# 🚀 SaaS Infrastructure Foundation

A centralized, containerized infrastructure for multi-tenant SaaS deployment, featuring **Master Nginx**, automated **Wildcard SSL**, and managed service stacks.

## 🏗️ Architecture Overview

- **Reverse Proxy**: Master Nginx container acting as the primary ingress.
- **SSL Management**: Certbot using Cloudflare DNS-01 challenge for automatic **Wildcard SSL** (`*.yourdomain.com`).
- **Core Services**: 
  - **Redis**: Mandatory caching layer.
  - **MySQL**: Optional root-managed database.
  - **RabbitMQ**: Optional message broker with pre-seeded definitions.
- **Routing Model**: Decentralized. Each service deploys a `.inc` snippet to `/etc/nginx/conf.d/locations/` to manage its own paths.

---

## 🛠️ Getting Started

### 1. Prerequisites
- A fresh Ubuntu server.
- **Cloudflare DNS**: API Token and Zone ID for SSL challenges.
- **GitHub Secrets**:
  - `SERVER_HOST`: Your server IP.
  - `SERVER_USER`: Deployment user (e.g., `root`).
  - `BOOTSTRAP_SSH_PRIVATE_KEY_BASE64`: Your server's SSH private key.
  - `CF_DNS_API_TOKEN` & `CF_ZONE_API_TOKEN`: Cloudflare credentials.

### 2. Manual Deployment
Trigger the **"Setup And Deploy Infra"** workflow from the Actions tab. You will be prompted for:
- **Service Domains**: Comma-separated list of domains for Wildcard SSL.
*   **ACME Email**: For Let's Encrypt registration.
*   **Passwords**: Root passwords for MySQL, RabbitMQ, and Redis.
*   **Toggles**: Choose whether to bootstrap MySQL and RabbitMQ.

---

## 📂 Service Integration

To add a new service to the infrastructure:
1. Create a location snippet (e.g., `myservice.inc`).
2. Define your proxy logic:
   ```nginx
   location /api/ {
       proxy_pass http://myservice:8000;
       include /etc/nginx/conf.d/proxy_params;
   }
   ```
3. Deploy the snippet to `infra/nginx/locations/` on the server and reload Nginx.

---

## 🔐 Database Management

MySQL and Redis are exposed on all interfaces (`0.0.0.0`) by default to allow management from your local host:
- **MySQL Port**: `3306`
- **Redis Port**: `6379`

*Note: It is strongly recommended to restrict access to these ports using the server's firewall (UFW) or Cloudflare IP whitelisting for production environments.*

---

## 📜 Deployment Workflow Logic

- **Environment**: Automatically determined by the **branch name** (e.g., `main`, `dev`, `uat`).
- **SSL Paths**: Certbot names the certificate directory after the **first** domain in your `SERVICE_DOMAIN` list.
- **Validation**: The workflow automatically validates that you've provided passwords for any service marked for installation.
