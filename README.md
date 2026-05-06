# Server Setup

Manual GitHub Action for preparing a fresh Ubuntu server.

This setup action installs Docker, creates the shared `public` Docker network,
and prepares selected deployment folders under `/opt/saas`.

## SSH Key

Recommended: create this secret in the `server_setup` repo:

```text
BOOTSTRAP_SSH_PRIVATE_KEY
```

The workflow also has an `ssh_private_key` input, but private keys are safer as
GitHub secrets than as workflow inputs. The key must log in as the selected
`user`, and that user must be able to run `sudo`.

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
