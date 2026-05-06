# Server Setup

Manual GitHub Action for preparing and deploying a fresh Ubuntu server.

This setup action installs Docker, creates the shared `public` Docker network,
and prepares selected deployment folders under `/opt/saas`.

The `Setup And Deploy Infra` workflow can also deploy the shared infrastructure
stack from this repo:

- Traefik
- MySQL
- RabbitMQ
- Redis
- Nginx catch-all UI router

## SSH Key

Recommended: create this secret in the `server_setup` repo:

```text
BOOTSTRAP_SSH_PRIVATE_KEY_BASE64
```

Create it from your Mac with:

```bash
base64 -i /path/to/server_private_key | tr -d '\n'
```

Raw `BOOTSTRAP_SSH_PRIVATE_KEY` is still supported, and the workflow also has an
`ssh_private_key` input, but base64 avoids newline/copy-paste corruption. The
key must be unencrypted, must log in as the selected `user`, and that user must
be able to run `sudo`.

## Workflow Inputs

- `host`: target server IP/host
- `environment`: GitHub environment, such as `dev`, `qa`, `uat`, or `main`
- `user`: existing sudo user, usually `root` or `ubuntu`
- `port`: SSH port, usually `22`
- `ssh_private_key`: optional private key input; prefer secret
- `deploy_root`: deployment root, default `/opt/saas`
- `install_docker`: install Docker and Docker Compose plugin
- `setup_nginx`: prepare Nginx UI deployment folder
- `setup_traefik`: prepare Traefik deployment folder
- `setup_mysql`: prepare MySQL deployment folder
- `setup_rabbitmq`: prepare RabbitMQ deployment folder
- `setup_redis`: prepare Redis deployment folder
- `setup_services`: prepare service deployment folders

The setup action prepares the server. Individual repos still deploy their own
containers and config using the configured SSH user, for example `root`.

## Single Repo Infra Deploy

Use `.github/workflows/setup-and-deploy.yml` when you want one button to both
bootstrap the server and start shared infrastructure. It expects environment
secrets/variables for MySQL, RabbitMQ, Redis, and Traefik DNS challenge.

Service repositories still deploy `authorization`, `workflow`, `notification`,
`audit`, and `document` individually.
