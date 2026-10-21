# server_setup

The shared part of a server that hosts several apps: the **nginx edge**, **certbot** (free Let's Encrypt certificates), **MySQL**, **Redis** and **RabbitMQ**, plus the generic `nginx-route` command. It knows no app: each service publishes its own address when it is deployed, and a certificate for that address is requested and renewed automatically.

## Folders on the server
- `/opt/infra`: this repository's services (nginx, MySQL, Redis, RabbitMQ: `docker-compose.yml`, `.env`, `nginx/`, `certs/`, `mysql/`). Synced by this workflow with `--delete`, so keep nothing of your own in it except what the services put there (`nginx/sites/`, `certs/`).
- `/opt/saas`: the application services (backend, frontend), one folder each, e.g. `/opt/saas/leezify_lease-main`. Their deploy workflows manage them.

## 1. *Actions -> Setup infrastructure -> Run workflow*

Tick what you want (re)deployed. **A ticked service is pulled and recreated with the current settings; an unticked one is not touched at all** (even if its settings changed). The first time on a server, tick `prepare_server` and every service. Later, tick only what changed.

| Input | Meaning |
|---|---|
| `server_host` | IP address of the server (required). |
| `ssh_user`, `ssh_port`, `infra_root` | `root`, `22`, `/opt/infra` by default. |
| `prepare_server` | Installs Docker if missing, creates the docker network, sets the firewall (22, 80, 443) and removes old rules that opened database ports. Tick it the first time. |
| `deploy_nginx`, `deploy_certbot`, `deploy_mysql`, `deploy_redis`, `deploy_rabbitmq` | The services. nginx restarts (a few seconds without HTTPS); MySQL, Redis and RabbitMQ restart too (their data is kept). |
| `mysql_username`, `mysql_password` | The MySQL login the services use (`root`, or another name that is created with every privilege). |
| `mysql_port`, `mysql_remote_ips`, `update_mysql_access` | Direct access to MySQL from your computer (port 3306, only for the listed addresses), see below. |
| `redis_password`, `rabbitmq_username`, `rabbitmq_password` | Redis and RabbitMQ logins. |
| `acme_email` | E-mail address for Let's Encrypt: it writes there before a certificate expires. Prefilled with `dodiyaashwin1994@gmail.com`. |
| `acme_staging` | Let's Encrypt's test service while trying things out (not trusted by browsers, no rate limits). Off for real use. |
| `rabbitmq_domain`, `rabbitmq_allowed_ips` | Publish the RabbitMQ management page, optionally only for some addresses. |

**A value left empty keeps the one already in `/opt/infra/.env` on the server**, so redeploying one service does not need every password again; a first install needs them typed. **Everything is typed as an input of the run; this repository keeps no secrets or variables of its own, except `SSH_PRIVATE_KEY`** (the deploy key for the server, a secret of the `main` environment; the branch picks the environment). The typed passwords are masked in the logs, but they stay visible in the run's inputs to everyone who can read this repository's workflow runs, so keep the repository private. dev and uat run on main's server: do not run this for them.

The values you give must be the ones the services use: `DB_USERNAME` and `DB_PASSWORD` (MySQL), `REDIS_PASSWORD`, `RABBITMQ_USERNAME` and `RABBITMQ_PASSWORD` of the service env files. **MySQL and RabbitMQ apply their password (and RabbitMQ its user) only when their data is first created**, so typing different ones later changes nothing for them; a non-root MySQL user is created or updated on every MySQL deploy (`infra/mysql/ensure-user.sh`); for root use `ALTER USER`.

### Connecting to MySQL from your computer (Workbench)
MySQL's port for tools outside the server is **`mysql_port` (3306, MySQL's usual port, by default)** and it is **closed until you give `mysql_remote_ips`**: your own public IP address (find it with `curl https://api.ipify.org`), or a network such as `203.0.113.0/24`, comma separated. Tick `deploy_mysql` to open it. Then, from a listed address, connect in Workbench with a normal Standard TCP/IP connection: host = the server, port `3306`, user `root` (or the MySQL user you set), password = the MySQL password. Anything wider than a /16 and IPv6 are refused. **`any` opens it to everyone** (type the word `any`): use it only if your own address keeps changing (a mobile connection), with a long, unique MySQL password: then nothing but the password protects the database, and `root` can be tried from anywhere. A tunnel avoids all of this.

How it is limited: the port is open to the internet (docker publishes it around the firewall), so MySQL itself refuses everyone else, and it checks the caller's address **before** the password: a stranger gets "Host ... is not allowed to connect" and never reaches a password prompt. `root` and the service user are valid only from the server's docker network (where the services run), from the machine itself and from the listed addresses.

- **Your IP changed?** Run again with the new address and tick **`update_mysql_access`** (no restart of MySQL needed). The old address stops working at once.
- **Close the port:** tick `deploy_mysql` with `mysql_remote_ips` empty.
- A different port: change `mysql_port` and tick `deploy_mysql`. The ports of the other services (6379, 5672, 15672, ssh, http, https) are refused.
- A tunnel (`ssh -L 3307:127.0.0.1:3306 root@<server>`) needs none of this and works from any address, as long as the port is published (it is on 127.0.0.1 even when closed to the outside).

### The RabbitMQ management page
With `rabbitmq_domain` the workflow publishes `https://<domain>` (the management web UI, container `rabbitmq:15672`) through the nginx edge; you sign in with the RabbitMQ user and password. Add an `A` record for the domain (the wildcard `A *` already covers a subdomain). Its certificate is requested from Let's Encrypt like any other host's: the domain must point to this server and port 80 must be reachable. If that fails the run shows a warning; fix the cause and run again. Because the page can administer the message broker, set `rabbitmq_allowed_ips` to your own addresses if you can. To take it down: `nginx-route remove --host <domain>` on the server.

### Do you need a bind address?
No. The apps reach Redis, RabbitMQ and MySQL through the docker network, which does not use the published ports at all. Redis and RabbitMQ stay on `127.0.0.1` (this machine only); MySQL's port (`mysql_port`) opens only through `mysql_remote_ips`, above. The RabbitMQ management port (15672) is always local; the page is published separately through nginx.

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
