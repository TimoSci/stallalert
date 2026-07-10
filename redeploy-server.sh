#!/bin/sh
# Rebuild and restart the StallAlert container. Run ON the server
# (stallalert@51.255.64.127) after rsyncing server/ up — see docs/deploy.md.
set -eu

cd "$HOME/stallalert/server"

docker build -t stallalert-server .

# First deploy has no container to remove; ignore those failures only.
docker stop stallalert 2>/dev/null || true
docker rm stallalert 2>/dev/null || true

docker run -d \
  --restart unless-stopped \
  --name stallalert \
  -p 127.0.0.1:4000:4000 \
  --env-file "$HOME/stallalert-deploy.env" \
  stallalert-server

echo "waiting for health..."
sleep 2
curl -fsS http://127.0.0.1:4000/v1/health && echo " deploy OK"
