# leezify_server_setup

The shared services of a Leezify server: the **nginx edge** (HTTPS with the certificate files from Hostinger), **MySQL**, **Redis** and **RabbitMQ**. MySQL, Redis and RabbitMQ listen on the server itself only (127.0.0.1); the apps reach them over the docker network `public`. The firewall opens SSH, HTTP and HTTPS only.

```
https://admin.<domain>                              -> ui-admin<suffix>  (the platform console)
https://<domain>, www and <account>.<domain>        -> ui-user<suffix>   (the lease app)
```

- **Run:** push to `main` (or `dev` / `uat`), or run *Setup infrastructure*. The branch picks the GitHub environment, whose secrets come from `leezify_env/leezify_server_setup/<env>.env`.
- **Do this first** on a new server, before deploying the authorization service, the lease service and the two UIs.
- **The certificate:** a **wildcard** certificate from Hostinger for `*.<domain>` that also covers `<domain>` itself (the same certificate lists both names). The workflow refuses to deploy a certificate that is about to expire (14 days), does not match its key, or does not cover the domain and the wildcard. A certificate for the bare domain only would show a warning on every account address. Install or renew with `leezify_env/scripts/set-tls.sh`; renewing is manual, so note the expiry date.
- **DNS** (Hostinger DNS zone of the domain): `A <domain>` and `A *` pointing at the server.
- **One environment per edge:** the nginx edge serves the single domain of the environment that was deployed. Environments on one server would need an extra server block and a certificate for their own domain.
- The edge sets `X-Forwarded-For` to the visitor's address and passes it on, so the apps log and rate-limit the real address.
