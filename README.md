# server_setup

The shared part of a server that hosts several apps: the **nginx edge**, **certbot** (free Let's Encrypt certificates), **MySQL**, **Redis** and **RabbitMQ**, plus the generic `nginx-route` command. It knows no app: each service publishes its own address when it is deployed, and a certificate for that address is requested and renewed automatically.

## Folders on the server
- `/opt/infra`: this repository's services (nginx, MySQL, Redis, RabbitMQ: `docker-compose.yml`, `.env`, `nginx/`, `certs/`, `mysql/`). Synced by this workflow with `--delete`, so keep nothing of your own in it except what the services put there (`nginx/sites/`, `certs/`).
- `/opt/saas`: the application services (backend, frontend), one folder each, e.g. `/opt/saas/leezify_lease-main`. Their deploy workflows manage them.

## 1. Install (once per server): *Actions -> Setup infrastructure -> Run workflow*

| Input | Meaning |
|---|---|
| `server_host` | IP address of the server to set up (required). |
| `ssh_user`, `ssh_port`, `infra_root` | `root`, `22`, `/opt/infra` by default. |
| `mysql_username` | The MySQL user the services log in with: `root` (default), or another name, which is created with every privilege (the lease service creates a database per account). |
| `mysql_password` | That user's password (also root's). |
| `redis_password` | Redis password. |
| `rabbitmq_username`, `rabbitmq_password` | RabbitMQ login. |
| `rabbitmq_domain` | Host name of the RabbitMQ management page (the web UI), e.g. `rabbitmq.ailease.tech`. Empty = not published. |
| `rabbitmq_allowed_ips` | Addresses allowed to open that page, e.g. `203.0.113.0/24,198.51.100.7`. Empty = everyone who knows the login. |
| `acme_email` | E-mail address for Let's Encrypt (required): it writes there before a certificate expires. |
| `acme_staging` | Tick it to use Let's Encrypt's test service while trying things out (its certificates are not trusted by browsers, but it has no rate limits). Leave it off for real use. |
| `*_bind_address` | Address the published port of MySQL / Redis / RabbitMQ listens on. **Leave `127.0.0.1`** (see below). |

**Everything is typed as an input of the run; this repository keeps no secrets or variables of its own, except `SSH_PRIVATE_KEY`** (the deploy key for the server, a secret of the `main` environment; the branch picks the environment). The typed passwords are masked in the logs, but they stay visible in the run's inputs to everyone who can read this repository's workflow runs, so keep the repository private. `server_host`, `mysql_password`, `redis_password` and `rabbitmq_password` are required. dev and uat run on main's server: do not run this for them. dev and uat run on main's server: do not run this for them.

It prepares Docker and a firewall (SSH, 80, 443), starts the four services, installs `nginx-route`, and is safe to run again (a password or setting changed). The host files and certificates the services have put on the server are kept.

The values you give here must be the ones the services use: `DB_USERNAME` and `DB_PASSWORD` (MySQL), `REDIS_PASSWORD`, `RABBITMQ_USERNAME` and `RABBITMQ_PASSWORD` of the service env files.

**MySQL, on a server that already has data:** the MySQL image sets root's password only on the very first start, so typing a different password later does not change root's. A non-root user is created or updated on every run (`infra/mysql/ensure-user.sh`: create if missing, set the password, grant everything), so *its* password can be changed by running the workflow again. To change root's password, do it in MySQL (`ALTER USER`).

### The RabbitMQ management page
With `rabbitmq_domain` the workflow publishes `https://<domain>` (the management web UI, container `rabbitmq:15672`) through the nginx edge; you sign in with the RabbitMQ user and password given above. Add an `A` record for the domain (the wildcard `A *` already covers a subdomain). Its certificate is requested from Let's Encrypt like any other host's: the domain must point to this server (a subdomain is already covered by the `A *` record) and port 80 must be reachable. If that fails the install still finishes and the run shows a warning; fix the cause and run again. Because the page can administer the message broker, set `rabbitmq_allowed_ips` to your office or VPN addresses if you can. To take the page down: `nginx-route remove --host <domain>` on the server.

### Do you need a bind address?
No. The apps reach MySQL, Redis and RabbitMQ through the docker network (`mysql`, `redis`, `rabbitmq`), which does not use the published ports at all. The published ports exist only for tools on the server itself (or an SSH tunnel, e.g. `ssh -L 3306:127.0.0.1:3306`), so `127.0.0.1` is right. Binding to `0.0.0.0` or the public IP puts the database on the internet: docker publishes ports around `ufw`, so the firewall does **not** protect it. Use it only for a private network address and with a firewall in front. The RabbitMQ management port (15672) is always local; the page is published separately through nginx (above).

## 2. Each app publishes itself: `nginx-route`

```bash
nginx-route add    --host app.example.com --target ui-user:80 [--cert FILE --key FILE] [--cert-domain example.com] [--max-body 15m] [--deny /internal,/admin] [--allow IP,IP/mask]
nginx-route remove --host app.example.com
nginx-route list
nginx-route check  [--host app.example.com] [--warn-days 30]
```

- The app's deploy workflow runs it over SSH after `docker compose up`. Inputs: domain, subdomain, port; the container is the app's alias on the network `public`.
- **Certificates are automatic.** The first time a host is published, `nginx-route add` asks Let's Encrypt for a certificate for it (HTTP-01: nginx answers the challenge on port 80, so the name must point to this server and port 80 must be reachable). The `certbot` container renews every certificate from 30 days before its end, and nginx reloads every 6 hours to pick the new one up. Nothing to buy, upload or renew by hand, and no wildcard is needed. A service **may** bring its own certificate instead (`--cert` / `--key`, from the `TLS_CERT_PEM_BASE64` / `TLS_KEY_PEM_BASE64` secrets of its environment): it is then checked and used, and a wildcard certificate already installed for the host's parent domain is reused before asking Let's Encrypt. Let's Encrypt allows 5 failed attempts per host per hour and 50 certificates per registered domain per week: use `acme_staging` for experiments.
- **`nginx-route check`** is run by every service deploy after it publishes: nginx is running and passes its test, and the host's certificate is readable, not expired (a warning 14 days before the end), covers the host, matches its key and has its intermediate certificate (a warning when it ends within 14 days, which for Let's Encrypt means the renewal is failing). It exits 1 on a failure, which fails the deploy. (It exists in the `nginx-route` that this workflow installs: run Setup infrastructure again after updating this repository.)
- One file per host (`nginx/sites/<host>.conf`): other apps' routes are never touched; two apps deploying at once wait for each other (lock). The container does not have to be running when its route is added.

## DNS (the domain's DNS zone)
`A @` and `A *` to the server's IP; leave the mail records as they are. A host under another domain needs its own `A` record there.

## Conventions for many apps
- One container per service, named for what it is (`auth`, `lease`, `billing`; `-dev` / `-uat` for the other environments), on the network `public`.
- One host per service: `<service>.<domain>`, `app` for the main web UI. Services that only other containers use get **no** route.
- Shared MySQL / Redis / RabbitMQ: one database name, one Redis DB number and one queue prefix per app and environment.
- The edge sets `X-Forwarded-For` to the visitor's address and supports WebSockets on every host.
