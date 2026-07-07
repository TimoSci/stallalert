#!/usr/bin/env bash
# server/scripts/capture_fixtures.sh
#
# Re-captures Windguru API fixtures for server/test/fixtures/windguru/.
# This reflects EMPIRICAL findings from a live capture session (see
# docs/windguru-api-notes.md for full detail and citations). Windguru's
# undocumented iapi.php may change shape over time -- if any curl below
# starts returning {"return":"error",...} or a non-2xx status, re-run the
# discovery steps in docs/windguru-api-notes.md rather than trusting this
# script blindly.
#
# Secrets: sourced from server/.env.capture (browser session capture) and
# server/.env.local (login credentials for the micro API). Neither file is
# committed (see server/.gitignore). Populate them before running:
#
#   server/.env.capture:
#     WG_UA=<browser User-Agent string>
#     WG_TOKEN=<X-WG-Token seen on spot-forecast/station_data requests>
#     WG_TOKEN_ALT=<X-WG-Token seen on custom-forecast/station_list requests>
#     WG_COOKIE=<full Cookie header from a logged-in browser session -- the
#                whole string; individual fields (session, login_md5,
#                deviceid, wgcookie, idu, ...) were NOT individually
#                sufficient in testing, only the complete cookie jar worked>
#     WG_SPOT_ID=<a saved spot id, e.g. from windguru.cz/<id_spot>>
#     WG_STATION_ID=<a live station id, e.g. from a station page>
#     WG_LAT=<latitude for the custom-location forecast>
#     WG_LON=<longitude for the custom-location forecast>
#
#   server/.env.local:
#     WG_USERNAME=<Windguru PRO username/email>
#     WG_PASSWORD=<Windguru PRO password>            (unused by this script)
#     WG_MICRO_PASSWORD=<PRO "micro API" secondary password>
#
# Usage: ./server/scripts/capture_fixtures.sh
#
# Findings baked into this script (see docs/windguru-api-notes.md for the
# full empirical record):
#   - Spot forecast (q=forecast&id_spot=...): needs User-Agent + Referer
#     only. No token, no cookie required. Works on both .cz and .net hosts.
#   - Custom lat/lon forecast (q=forecast&lat=...&lon=...): PRO-gated. The
#     FULL captured session cookie is required (partial subsets such as
#     session+login_md5 alone, or deviceid+wgcookie alone, both returned
#     401). X-WG-Token was NOT required when the cookie was present.
#   - Live station data (q=station_data): worked with just User-Agent +
#     Referer for the tested station -- no token, no cookie needed. This
#     may vary for stations not owned/visible to the account; if you get a
#     401, add -H "X-WG-Token: $WG_TOKEN" and/or -b "$WG_COOKIE".
#   - Station list (q=station_list): requires User-Agent + Referer (as of
#     2026-07-07; bare requests return 401 -- see docs/windguru-api-notes.md).
#   - rundef: safe to omit entirely -- server always serves the latest
#     model run. A stale/explicit rundef value was also silently ignored
#     in favor of the latest run (Windguru does not error on stale rundef).
#   - id_model: 3 (GFS 13 km) is available for arbitrary custom lat/lon.
#     id_model=38 returned 404 "outside grid" (regional model, not global).
#     id_model=wg (literal) returned 200 with "Data not available!" -- the
#     WG-blend model does not appear to be selectable for arbitrary custom
#     coordinates via this endpoint.
#   - .net vs .cz hosts were interchangeable for every endpoint tested
#     (same cookie/token worked cross-host).
#   - Micro API: m=gfs (and omitting m, which defaults to gfs) returned a
#     full text forecast table. m=wg returned a near-empty page (SST line
#     only, no forecast table) -- the WG-blend model isn't available via
#     the micro API for this location either.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(dirname "$SCRIPT_DIR")"
DIR="$SERVER_DIR/test/fixtures/windguru"
mkdir -p "$DIR"

# --- load secrets -----------------------------------------------------
for envfile in "$SERVER_DIR/.env.capture" "$SERVER_DIR/.env.local"; do
  if [[ -f "$envfile" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$envfile"
    set +a
  else
    echo "warning: $envfile not found; some fixtures may fail" >&2
  fi
done

: "${WG_UA:?set WG_UA in server/.env.capture}"
: "${WG_SPOT_ID:?set WG_SPOT_ID in server/.env.capture}"
: "${WG_STATION_ID:?set WG_STATION_ID in server/.env.capture}"
: "${WG_LAT:?set WG_LAT in server/.env.capture}"
: "${WG_LON:?set WG_LON in server/.env.capture}"
: "${WG_COOKIE:?set WG_COOKIE in server/.env.capture (full Cookie header string)}"

sleep_between() { sleep 2.5; }

# --- 1. Spot forecast (id_model=3, rundef omitted -> latest run) ------
echo "1/5 spot forecast..."
curl -sf \
  -H "Referer: https://www.windguru.cz/" \
  -H "User-Agent: $WG_UA" \
  "https://www.windguru.net/int/iapi.php?q=forecast&id_model=3&id_spot=${WG_SPOT_ID}&ai=1&WGCACHEABLE=21600" \
  | python3 -m json.tool > "$DIR/forecast.json"
sleep_between

# --- 2. Custom lat/lon forecast (PRO; requires full session cookie) ---
echo "2/5 custom lat/lon forecast..."
curl -sf \
  -H "Referer: https://www.windguru.cz/?lat=${WG_LAT}&lon=${WG_LON}" \
  -H "User-Agent: $WG_UA" \
  -b "$WG_COOKIE" \
  "https://www.windguru.cz/int/iapi.php?q=forecast&id_model=3&lat=${WG_LAT}&lon=${WG_LON}&alt=218" \
  | python3 -m json.tool > "$DIR/forecast_custom.json"
sleep_between

# --- 3. Live station data: fresh 60-minute window, avg_minutes=5 ------
echo "3/5 live station data..."
FROM=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc)-timedelta(minutes=60)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
TO=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))")
curl -sf -G \
  -H "Referer: https://www.windguru.cz/${WG_SPOT_ID}" \
  -H "User-Agent: $WG_UA" \
  "https://www.windguru.cz/int/iapi.php" \
  --data-urlencode "q=station_data" \
  --data-urlencode "id_station=${WG_STATION_ID}" \
  --data-urlencode "from=${FROM}" \
  --data-urlencode "to=${TO}" \
  --data-urlencode "avg_minutes=5" \
  --data-urlencode "graph_info=1" \
  | python3 -m json.tool > "$DIR/station_current.json"
sleep_between

# --- 4. Station list (global; no auth needed; trim if huge) -----------
echo "4/5 station list..."
RAW_STATIONS="$(mktemp)"
curl -sf \
  -H "Referer: https://www.windguru.cz/" \
  -H "User-Agent: $WG_UA" \
  "https://www.windguru.net/int/iapi.php?q=station_list&id_type=0&seconds=1800&seconds_alive=172800&WGCACHEABLE=30" \
  > "$RAW_STATIONS"

RAW_SIZE=$(wc -c < "$RAW_STATIONS" | tr -d ' ')
if [[ "$RAW_SIZE" -gt 300000 ]]; then
  echo "  station list is ${RAW_SIZE} bytes (> 300KB) -- trimming to stations" \
       "within ~250km of ${WG_LAT},${WG_LON} plus ~20 others"
  python3 - "$RAW_STATIONS" "$WG_LAT" "$WG_LON" "$DIR/stations_list.json" <<'PYEOF'
import json, math, random, sys

raw_path, lat0, lon0, out_path = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]

with open(raw_path) as f:
    data = json.load(f)

def haversine(lat1, lon1, lat2, lon2):
    R = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2) ** 2
    return 2 * R * math.asin(math.sqrt(a))

near = [s for s in data if haversine(lat0, lon0, s.get("lat", 0), s.get("lon", 0)) <= 250]
far = [s for s in data if s not in near]
random.seed(42)
extra = random.sample(far, min(20, len(far)))

with open(out_path, "w") as f:
    json.dump(near + extra, f, indent=2, ensure_ascii=False)
PYEOF
else
  python3 -m json.tool "$RAW_STATIONS" > "$DIR/stations_list.json"
fi
rm -f "$RAW_STATIONS"
sleep_between

# --- 5. Micro API fallback (text; PRO secondary password) -------------
echo "5/5 micro API..."
: "${WG_USERNAME:?set WG_USERNAME in server/.env.local}"
: "${WG_MICRO_PASSWORD:?set WG_MICRO_PASSWORD in server/.env.local}"
curl -sf \
  "https://micro.windguru.cz/?lat=${WG_LAT}&lon=${WG_LON}&u=${WG_USERNAME}&p=${WG_MICRO_PASSWORD}&m=gfs" \
  > "$DIR/micro_forecast.txt"

echo "Fixtures written to $DIR"
echo "REMEMBER: grep new fixtures for session/login_md5/deviceid/idu/tokens/username" \
     "before committing (see docs/windguru-api-notes.md, Sanitization)."
