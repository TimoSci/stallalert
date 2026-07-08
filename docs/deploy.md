# Deploying the StallAlert server

## Current production deployment (as of 2026-07-08)

- Host: OVH box `51.255.64.127` (`ns3024870.ip-51-255-64.eu`), Ubuntu 22.04,
  SSH user `stallalert`, repo cloned at `~/stallalert`.
- Docker: **snap** package (`snap list docker`). Two snap quirks: the
  `docker` group had to be created manually (`addgroup --system docker` +
  `adduser stallalert docker` + `snap disable docker && snap enable docker`
  for the socket group to apply), and snap auto-refreshes restart the daemon
  at arbitrary times — `--restart unless-stopped` covers the containers.
- DNS: root A record `stallalert.com` -> `51.255.64.127` (Namecheap).
- Caddy: a pre-existing **custom** install owned by the `evomelodia` user —
  unit `/etc/systemd/system/caddy.service`, binary
  `/home/evomelodia/.local/bin/caddy`, config
  `/home/evomelodia/caddy/Caddyfile` (NOT `/etc/caddy/Caddyfile`). The
  `stallalert.com` reverse-proxy block was appended there; certificates live
  under `/home/evomelodia/.local/share/caddy`. Reload with
  `sudo systemctl reload caddy`; validate with
  `sudo -u evomelodia /home/evomelodia/.local/bin/caddy validate --config /home/evomelodia/caddy/Caddyfile`.
- Env: `~/stallalert-deploy.env` on the server (chmod 600), scp'd from the
  workstation's git-ignored `server/.env.deploy`. That file holds the live
  `API_TOKEN` (the watch app needs the same one) — it is a plain
  `KEY=value`-per-line file for `docker --env-file`; do NOT `source` it in a
  shell (the unquoted `WG_COOKIE` breaks shell parsing).

## Prerequisites
- A host with a fixed IP, Docker, and ports 80/443 open.
- A DNS A record pointing your chosen hostname at the fixed IP (this
  deployment uses the root domain `stallalert.com`).

## Build the image
```bash
cd server
docker build -t stallalert-server .
```

## Run the service
```bash
docker run -d --restart unless-stopped --name stallalert \
  -p 127.0.0.1:4000:4000 \
  --env-file ~/stallalert-deploy.env \
  stallalert-server
```
The env file contains `API_TOKEN`, `WG_USERNAME`, `WG_PASSWORD`,
`WG_MICRO_PASSWORD`, `WG_COOKIE`, one unquoted `KEY=value` per line.
Record the `API_TOKEN` — the watch app needs it. The server binds only to
`127.0.0.1:4000` on the host; it is not reachable from outside until Caddy
proxies to it (see below).

`WG_USERNAME` **is** consumed by the app: together with `WG_MICRO_PASSWORD`
it authenticates the `micro.windguru.cz` fallback forecast (see below).
`WG_PASSWORD` is accepted by the container but not currently consumed by the
app — no automated Windguru login flow was found (see
`docs/windguru-api-notes.md`, "Open risk: session-cookie acquisition"), so
set it anyway for forward-compatibility, but it doesn't do anything yet.

`WG_COOKIE` **is** consumed by the app and matters in practice: it must be
the **full** session cookie string copy-pasted from a logged-in
`windguru.cz` browser session (all fields — `langc`, `deviceid`, `g_state`,
`idu`, `login_md5`, `session`, `wgcookie` — not a subset). It gates the
custom lat/lon forecast endpoint, the server's primary data source. There is
no programmatic way to obtain or refresh it: **when it expires, log into
windguru.cz in a browser, copy the full `Cookie` request header value for a
request to windguru.cz, and restart the container with the updated
`WG_COOKIE`.** Until refreshed, forecast calls fall back automatically to
the `micro.windguru.cz` API (requires `WG_USERNAME` + `WG_MICRO_PASSWORD`;
if either is unset, forecast calls instead return `cookie_expired` errors,
or `auth_required` if `WG_COOKIE` was never set, rather than crashing). When
the micro fallback is in effect, the served `/v1/conditions` payload's
`forecast.model` field reads `"gfs-micro"` instead of the usual model name,
and `docker logs stallalert` shows a warning containing "micro fallback" —
both are the signal to go refresh `WG_COOKIE`. Only `API_TOKEN` is required
for the server to boot; the release fails fast at startup with a clear
error if `API_TOKEN` is missing.

## TLS via Caddy (automatic Let's Encrypt)
Append to the Caddyfile (on this host: `/home/evomelodia/caddy/Caddyfile`;
on a fresh host with packaged Caddy: `/etc/caddy/Caddyfile`):
```
stallalert.com {
    reverse_proxy 127.0.0.1:4000
}
```
Then:
```bash
sudo systemctl reload caddy
```
Caddy fetches the Let's Encrypt certificate automatically within ~30 s of
the reload (verified live 2026-07-08; cert issued for stallalert.com).

## Verify from outside
```bash
curl https://stallalert.com/v1/health
# -> {"status":"ok"}

curl -H "Authorization: Bearer $API_TOKEN" \
  "https://stallalert.com/v1/conditions?lat=39.92&lon=3.09"
# -> 200 with forecast + nearest station (verified live 2026-07-08)
```

## Updating (e.g. after a Windguru format change)
Rebuild the image, `docker stop` + rerun. The watch app needs no update.

## Smoke-testing locally
Before deploying, confirm the image works locally:
```bash
docker run -d --rm -p 4000:4000 \
  -e API_TOKEN=localtest -e WG_USERNAME=x -e WG_PASSWORD=x -e WG_MICRO_PASSWORD=x \
  --name stallalert-smoke stallalert-server

curl -s localhost:4000/v1/health
# -> {"status":"ok"}

curl -s -o /dev/null -w "%{http_code}" "localhost:4000/v1/conditions?lat=1&lon=1"
# -> 401

docker stop stallalert-smoke
```
