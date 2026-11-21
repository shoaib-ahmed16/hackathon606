# Serving Foooh! over HTTPS

The web container speaks plain HTTP on port 8080, so sign-in and the session token cross the network unencrypted. Put a TLS front in
front of it. It needs a **hostname** that points at the server (a bare IP cannot get a normal certificate).

## Easiest: Caddy (gets and renews the certificate by itself)
On the server, next to the project (`DOMAIN` is your hostname, ports 80 and 443 must be open to the internet for the certificate):

```
docker run -d --name foooh-tls --restart unless-stopped --network host \
  -v caddy-data:/data caddy:2 \
  caddy reverse-proxy --from DOMAIN --to 127.0.0.1:8080
```

Then open `https://DOMAIN`. To stop serving the plain port to the outside, bind it to the machine only: in `.env` there is no switch for the
web port yet, so edit `docker-compose.yml` (`'127.0.0.1:${HTTP_PORT:-8080}:80'`) and run `docker compose up -d`.

## What the app already does for you
* the session token is sent in the `Authorization` header only; the live stream uses a one-time 30-second ticket, so no token appears in URLs or logs
* security headers (CSP, frame, nosniff, referrer) and no nginx version on every response
* the API docs are off (`ENABLE_DOCS=1` in `.env` turns them on for a dev machine) and are never reachable through the public port
* the API port 8888 is bound to the machine only (`API_BIND=0.0.0.0` to open it)
* the sign-in page does not print the demo logins (`SHOW_DEMO_USERS=true` in `.env` for a demo build)
* the generic record writer accepts only the tables the screens use, per role; deleting a case is admin-only

## Still open (decide before a public launch)
* the session token is kept in the browser's localStorage; an HttpOnly cookie would be safer but needs CSRF protection
* HSTS (add `Strict-Transport-Security` once HTTPS is the only way in)
