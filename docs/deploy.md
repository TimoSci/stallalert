# Deploying the StallAlert server

## Prerequisites
- A host with a fixed IP, Docker, and ports 80/443 open.
- A DNS A record: `stallalert.<yourdomain>` -> `<fixed IP>`.

## Build the image
```bash
cd server
docker build -t stallalert-server .
```

## Run the service
```bash
docker run -d --restart unless-stopped --name stallalert \
  -p 127.0.0.1:4000:4000 \
  -e API_TOKEN="$(openssl rand -hex 32)" \
  -e WG_USERNAME=... -e WG_PASSWORD=... \
  -e WG_COOKIE="..." \
  stallalert-server
```
Record the `API_TOKEN` — the watch app needs it. The server binds only to
`127.0.0.1:4000` on the host; it is not reachable from outside until Caddy
proxies to it (see below).

`WG_USERNAME` / `WG_PASSWORD` are accepted by the container but not
currently consumed by the app — no automated Windguru login flow was found
(see `docs/windguru-api-notes.md`, "Open risk: session-cookie acquisition"),
so set them anyway for forward-compatibility, but they don't do anything yet.

`WG_COOKIE` **is** consumed by the app and matters in practice: it must be
the **full** session cookie string copy-pasted from a logged-in
`windguru.cz` browser session (all fields — `langc`, `deviceid`, `g_state`,
`idu`, `login_md5`, `session`, `wgcookie` — not a subset). It gates the
custom lat/lon forecast endpoint, the server's primary data source. There is
no programmatic way to obtain or refresh it: **when it expires, log into
windguru.cz in a browser, copy the full `Cookie` request header value for a
request to windguru.cz, and restart the container with the updated
`WG_COOKIE`.** Until refreshed, forecast calls return `cookie_expired`
errors (or `auth_required` if `WG_COOKIE` was never set) rather than
crashing. Only `API_TOKEN` is required for the server to boot; the release
fails fast at startup with a clear error if `API_TOKEN` is missing.

## TLS via Caddy (automatic Let's Encrypt)
`/etc/caddy/Caddyfile`:
```
stallalert.<yourdomain> {
    reverse_proxy 127.0.0.1:4000
}
```
Then:
```bash
systemctl reload caddy
```

> The Caddy/DNS/TLS steps above are standard configuration and have not
> been exercised as part of this task (no live domain or Caddy instance was
> available) — verify them against your own host before relying on them.

## Verify from outside
```bash
curl https://stallalert.<yourdomain>/v1/health
# -> {"status":"ok"}

curl -H "Authorization: Bearer $API_TOKEN" \
  "https://stallalert.<yourdomain>/v1/conditions?lat=52.36&lon=5.04"
```

## Updating (e.g. after a Windguru format change)
Rebuild the image, `docker stop` + rerun. The watch app needs no update.

## Smoke-testing locally
Before deploying, confirm the image works locally:
```bash
docker run -d --rm -p 4000:4000 \
  -e API_TOKEN=localtest -e WG_USERNAME=x -e WG_PASSWORD=x \
  --name stallalert-smoke stallalert-server

curl -s localhost:4000/v1/health
# -> {"status":"ok"}

curl -s -o /dev/null -w "%{http_code}" "localhost:4000/v1/conditions?lat=1&lon=1"
# -> 401

docker stop stallalert-smoke
```
