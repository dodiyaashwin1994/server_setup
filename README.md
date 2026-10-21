# server_setup

The shared part of a server that hosts several apps: the **nginx edge**, **MySQL**, **Redis** and **RabbitMQ**, plus the generic `nginx-route` command. It knows no app and no certificate: each service publishes its own address, **and brings its own certificate**, when it is deployed.

## Folders on the server
- `/opt/infra`: this repository's services (nginx, MySQL, Redis, RabbitMQ: `docker-compose.yml`, `.env`, `nginx/`, `certs/`, `mysql/`). Synced by this workflow with `--delete`, so keep nothing of your own in it except what the services put there (`nginx/sites/`, `certs/`).
- `/opt/saas`: the application services (backend, frontend), one folder each, e.g. `/opt/saas/leezify_lease-main`. Their deploy workflows manage them.

## 1. Install (once per server): *Actions -> Setup infrastructure -> Run workflow*

| Input | Meaning |
|---|---|
| `server_host` | IP address of the server to set up (or the `SERVER_HOST` secret). |
| `ssh_user`, `ssh_port`, `infra_root` | `root`, `22`, `/opt/infra` by default. |
| `mysql_username` | The MySQL user the services log in with: `root` (default), or another name, which is created with every privilege (the lease service creates a database per account). |
| `mysql_password` | That user's password (also root's). |
| `redis_password` | Redis password. |
| `rabbitmq_username`, `rabbitmq_password` | RabbitMQ login. |
| `rabbitmq_domain` | Host name of the RabbitMQ management page (the web UI), e.g. `rabbitmq.ailease.tech`. Empty = not published. |
| `rabbitmq_allowed_ips` | Addresses allowed to open that page, e.g. `203.0.113.0/24,198.51.100.7`. Empty = everyone who knows the login. |
| `*_bind_address` | Address the published port of MySQL / Redis / RabbitMQ listens on. **Leave `127.0.0.1`** (see below). |

Every value can instead be a secret of the GitHub environment (`SERVER_HOST`, `MYSQL_USERNAME`, `MYSQL_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_USERNAME`, `RABBITMQ_PASSWORD`; the SSH key is always the secret `SSH_PRIVATE_KEY`); what is typed wins. **Prefer secrets for passwords**: a typed input stays visible to everyone who can read this repository's workflow runs (the workflow masks it in the logs only). The branch (`main`, `dev`, `uat`) picks the environment whose secrets are used. dev and uat run on main's server: do not run this for them.

It prepares Docker and a firewall (SSH, 80, 443), starts the four services, installs `nginx-route`, and is safe to run again (a password or setting changed). The host files and certificates the services have put on the server are kept.

The values you give here must be the ones the services use: `DB_USERNAME` and `DB_PASSWORD` (MySQL), `REDIS_PASSWORD`, `RABBITMQ_USERNAME` and `RABBITMQ_PASSWORD` of the service env files.

**MySQL, on a server that already has data:** the MySQL image sets root's password only on the very first start, so typing a different password later does not change root's. A non-root user is created or updated on every run (`infra/mysql/ensure-user.sh`: create if missing, set the password, grant everything), so *its* password can be changed by running the workflow again. To change root's password, do it in MySQL (`ALTER USER`).

### The RabbitMQ management page
With `rabbitmq_domain` the workflow publishes `https://<domain>` (the management web UI, container `rabbitmq:15672`) through the nginx edge; you sign in with the RabbitMQ user and password given above. Add an `A` record for the domain (the wildcard `A *` already covers a subdomain). It needs a **certificate for that domain**: the secrets `TLS_CERT_PEM_BASE64` / `TLS_KEY_PEM_BASE64` of this environment, or one already installed on the server for the domain (a service of the same domain, deployed earlier, has put it there). Without either the install still finishes and the run shows a warning; run again once the certificate exists. Because the page can administer the message broker, set `rabbitmq_allowed_ips` to your office or VPN addresses if you can. To take the page down: `nginx-route remove --host <domain>` on the server.

### Do you need a bind address?
No. The apps reach MySQL, Redis and RabbitMQ through the docker network (`mysql`, `redis`, `rabbitmq`), which does not use the published ports at all. The published ports exist only for tools on the server itself (or an SSH tunnel, e.g. `ssh -L 3306:127.0.0.1:3306`), so `127.0.0.1` is right. Binding to `0.0.0.0` or the public IP puts the database on the internet: docker publishes ports around `ufw`, so the firewall does **not** protect it. Use it only for a private network address and with a firewall in front. The RabbitMQ management port (15672) is always local; the page is published separately through nginx (above).

## 2. Each app publishes itself: `nginx-route`

```bash
nginx-route add    --host app.example.com --target ui-user:80 [--cert FILE --key FILE] [--cert-domain example.com] [--max-body 15m] [--deny /internal,/admin] [--allow IP,IP/mask]
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
