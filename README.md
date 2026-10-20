# leezify_server_setup

The shared part of a Leezify server: the **nginx edge** (HTTPS, certificates from Hostinger), **MySQL**, **Redis** and **RabbitMQ**. MySQL, Redis and RabbitMQ listen on the server itself only (127.0.0.1); apps reach them over the docker network `public`. The firewall opens SSH, HTTP and HTTPS only.

The server is meant to host many apps. Every host name has **its own nginx file** (`infra/nginx/sites/<host>.conf` on the server), so adding or removing one never touches the others.

```
https://app.ailease.tech            -> ui-user:80    the lease app (one address for every client; the account is chosen after sign in)
https://admin.ailease.tech          -> ui-admin:80   the platform console
https://authorization.ailease.tech  -> auth:8000     authorization API
https://lease.ailease.tech          -> lease:8001    lease API
```

## Run it: *Actions -> Setup infrastructure -> Run workflow*

| Input | Meaning |
|---|---|
| `mode = full` | First time on a server, or to change a password or setting: installs Docker, sets the firewall, starts nginx / MySQL / Redis / RabbitMQ, then adds the routes. |
| `mode = routes` | Only adds, changes or removes host names. **Nothing installed is touched** (no packages, no compose change, no database restart). nginx is tested before the reload; if it rejects the files the previous ones are put back. |
| `routes` | `host=container:port`, comma separated. Prefilled with the four hosts above; empty uses the `ROUTES` secret. |
| `remove` | Hosts to delete (the app itself keeps running; only its address goes). |

The branch picks the environment (`main`, `dev`, `uat`) and its secrets (from `leezify_env/leezify_server_setup/<env>.env`). dev and uat share the server of main: run them with `mode = routes` (hosts such as `app-dev.ailease.tech=ui-user-dev:80`, already in their `ROUTES`), never `full`.

## Adding another app or domain later
1. Deploy the app as a container that joins the network `public` with a name (an alias), e.g. `billing:8000`.
2. Run the workflow with `mode = routes` and `routes = billing.ailease.tech=billing:8000`. The same wildcard certificate covers every `*.ailease.tech` host.
3. A **different domain** (`shop.net`) needs its own wildcard certificate first:
   `bash leezify_env/scripts/set-tls.sh main <cert> <key> [ca-bundle] shop.net`, then `push-secrets.sh`, then the workflow. A certificate already on the server is reused, so the secret is only needed to install or renew it.

## Certificates
- Hostinger's **wildcard** certificate for `*.<domain>` (it must also list `<domain>`), with its private key (kept from when the CSR was made). Renewal is manual: the workflow refuses a certificate that expires within 14 days, does not match its key, or is not a wildcard.
- On the server they live in `infra/certs/<domain>/{fullchain,privkey}.pem`.

## DNS (Hostinger DNS zone)
`A @` and `A *` pointing at the server's IP (the wildcard covers every host above). Leave the mail records as they are. A host under another domain needs its own `A` records there.

## Suggested layout for many apps
- One container per service, named for what it is (`auth`, `lease`, `billing`), with `-dev` / `-uat` for the other environments, all on the network `public`.
- One host per service: `<service>.<domain>`, plus `app` for the main web UI. Keep the user-facing UI and the APIs on separate hosts; give internal-only services **no** route (other containers reach them by name).
- Shared MySQL / Redis / RabbitMQ: one database name, one Redis DB number and one queue prefix per app and environment.
- The edge sets `X-Forwarded-For` to the visitor's address, so apps log and rate-limit the real address; WebSockets work on every host.
