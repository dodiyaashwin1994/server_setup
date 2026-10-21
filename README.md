# server_setup

The shared part of a server that hosts several apps: the **nginx edge**, **MySQL**, **Redis** and **RabbitMQ**, plus the generic `nginx-route` command. It knows no app and no certificate: each service publishes its own address, **and brings its own certificate**, when it is deployed.

## 1. Install (once per server): *Actions -> Setup infrastructure -> Run workflow*

| Input | Meaning |
|---|---|
| `server_host` | IP address of the server to set up (or the `SERVER_HOST` secret). |
| `ssh_user`, `ssh_port`, `deploy_root` | `root`, `22`, `/opt/leezify` by default. |
| `mysql_username` | The MySQL user the services log in with: `root` (default), or another name, which is created with every privilege (the lease service creates a database per account). |
| `mysql_password` | That user's password (also root's). |
| `redis_password` | Redis password. |
| `rabbitmq_username`, `rabbitmq_password` | RabbitMQ login. |
| `*_bind_address` | Address the published port of MySQL / Redis / RabbitMQ listens on. **Leave `127.0.0.1`** (see below). |

Every value can instead be a secret of the GitHub environment (`SERVER_HOST`, `MYSQL_USERNAME`, `MYSQL_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD`; the SSH key is always the secret `SSH_PRIVATE_KEY`); what is typed wins. **Prefer secrets for passwords**: a typed input stays visible to everyone who can read this repository's workflow runs (the workflow masks it in the logs only). The branch (`main`, `dev`, `uat`) picks the environment whose secrets are used. dev and uat run on main's server: do not run this for them.

It prepares Docker and a firewall (SSH, 80, 443), starts the four services, installs `nginx-route`, and is safe to run again (a password or setting changed). The host files and certificates the services have put on the server are kept.

The values you give here must be the ones the services use: `DB_USERNAME` and `DB_PASSWORD` (MySQL), `REDIS_PASSWORD`, `RABBITMQ_USERNAME` and `RABBITMQ_PASSWORD` of the service env files.

**MySQL, on a server that already has data:** the MySQL image sets root's password only on the very first start, so typing a different password later does not change root's. A non-root user is created or updated on every run (`infra/mysql/ensure-user.sh`: create if missing, set the password, grant everything), so *its* password can be changed by running the workflow again. To change root's password, do it in MySQL (`ALTER USER`).

### Do you need a bind address?
No. The apps reach MySQL, Redis and RabbitMQ through the docker network (`mysql`, `redis`, `rabbitmq`), which does not use the published ports at all. The published ports exist only for tools on the server itself (or an SSH tunnel, e.g. `ssh -L 3306:127.0.0.1:3306`), so `127.0.0.1` is right. Binding to `0.0.0.0` or the public IP puts the database on the internet: docker publishes ports around `ufw`, so the firewall does **not** protect it. Use it only for a private network address and with a firewall in front. The RabbitMQ management page (15672) is always local.

## 2. Each app publishes itself: `nginx-route`

```bash
nginx-route add    --host app.example.com --target ui-user:80 [--cert FILE --key FILE] [--cert-domain example.com] [--max-body 15m] [--deny /internal,/admin]
nginx-route remove --host app.example.com
nginx-route list
```

- The app's deploy workflow runs it over SSH after `docker compose up`. Inputs: domain, subdomain, port; the container is the app's alias on the network `public`.
- **Certificates come with the service**: its env holds `TLS_CERT_PEM_BASE64` / `TLS_KEY_PEM_BASE64`; the deploy uploads them and `nginx-route` checks them (not expired, matches the key, covers the host) and installs them in `certs/<domain>/` (the host's parent when the certificate is a wildcard for it, else the host itself), keeping a copy only on the server. Without a certificate in the env, the one already installed for that domain is used; if there is none the deploy fails and says so. If nginx rejects the result, the previous host file and certificate are put back.
- One file per host (`nginx/sites/<host>.conf`): other apps' routes are never touched; two apps deploying at once wait for each other (lock). The container does not have to be running when its route is added.

## DNS (the domain's DNS zone)
`A @` and `A *` to the server's IP; leave the mail records as they are. A host under another domain needs its own `A` records there and its own certificate in that service's env.

## Conventions for many apps
- One container per service, named for what it is (`auth`, `lease`, `billing`; `-dev` / `-uat` for the other environments), on the network `public`.
- One host per service: `<service>.<domain>`, `app` for the main web UI. Services that only other containers use get **no** route.
- Shared MySQL / Redis / RabbitMQ: one database name, one Redis DB number and one queue prefix per app and environment.
- The edge sets `X-Forwarded-For` to the visitor's address and supports WebSockets on every host.
