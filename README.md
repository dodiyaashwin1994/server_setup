# leezify_server_setup

The shared part of a server that hosts several apps: the **nginx edge** (HTTPS, certificates from Hostinger), **MySQL**, **Redis** and **RabbitMQ**. MySQL, Redis and RabbitMQ listen on the server itself only (127.0.0.1); apps reach them over the docker network `public`. The firewall opens SSH, HTTP and HTTPS only.

This repo knows **no app**. Each app publishes its own address when it is deployed, with the `nginx-route` command this setup installs on the server.

## 1. Install (once per server): *Actions -> Setup infrastructure -> Run workflow*

| Input | Meaning |
|---|---|
| `mode = install` | Docker, firewall, nginx, MySQL, Redis, RabbitMQ, the certificates and `nginx-route`. Safe to run again (a password or setting changed); the host files apps have published are kept. |
| `mode = certificates` | Only installs or renews certificates and reloads nginx. |
| `domains` | Other domains to install a certificate for, besides `SERVICE_DOMAIN` (comma separated). |

The branch picks the GitHub environment (`main`, `dev`, `uat`); its secrets come from `leezify_env/leezify_server_setup/<env>.env`. dev and uat run on main's server: do not run *install* for them.

## 2. Each app publishes itself: `nginx-route`

```bash
nginx-route add    --host app.ailease.tech --target ui-user:80 [--cert-domain ailease.tech] [--max-body 15m]
nginx-route remove --host app.ailease.tech
nginx-route list
```

- The app's deploy workflow runs it over SSH after `docker compose up`. Its inputs are the **domain**, **subdomain** and **port**; the container is the app's alias on the network `public`.
- One file per host (`infra/nginx/sites/<host>.conf` on the server): the routes of other apps are never touched, and two apps deploying at the same time wait for each other (lock).
- nginx is tested before it reloads; if it rejects the change the previous file is put back and the command fails (the deploy fails with it).
- The container does not have to be running when the route is added.
- A route needs a certificate on the server for the host's parent domain (`app.ailease.tech` -> `ailease.tech`) or for the host itself. Without one the command says so and changes nothing.

## Certificates
- Hostinger's **wildcard** certificate for `*.<domain>` (it must also list `<domain>`), with the private key kept from when the CSR was made. Renewal is manual: the workflow refuses a certificate that expires within 14 days, does not match its key, or is not a wildcard.
- `bash leezify_env/scripts/set-tls.sh <env> <cert> <key> [ca-bundle] [domain]` stores it in the env repo (leave `domain` out for `SERVICE_DOMAIN`), `push-secrets.sh` loads it into GitHub, then run this workflow (`certificates` is enough to renew).
- On the server: `infra/certs/<domain>/{fullchain,privkey}.pem`.
- A new domain: install its certificate first (`domains` input), then deploy the app with that domain.

## DNS (Hostinger DNS zone of each domain)
`A @` and `A *` to the server's IP; leave the mail records as they are.

## Conventions for many apps
- One container per service, named for what it is (`auth`, `lease`, `billing`; `-dev` / `-uat` for the other environments), on the network `public`.
- One host per service: `<service>.<domain>`, `app` for the main web UI. Services that only other containers use get **no** route.
- Shared MySQL / Redis / RabbitMQ: one database name, one Redis DB number and one queue prefix per app and environment.
- The edge sets `X-Forwarded-For` to the visitor's address and supports WebSockets on every host.
