#!/bin/sh
# Samples the Apple Watch's CoreDevice connection state every 20 s so
# fast-vs-slow Xcode "Connecting..." runs can be correlated with
# conditions. Ctrl-C to stop. Columns: time | devicectl state | utun count
# (Mullvad/Tailscale create utuns; peer-to-peer discovery breaks when up).
set -eu

while true; do
  ts=$(date +%H:%M:%S)
  state=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/Watch/ {for (i=NF; i>0; i--) if ($i ~ /connected|available|unavailable/) {print $i; exit}}')
  utuns=$(ifconfig 2>/dev/null | grep -c '^utun' || true)
  echo "$ts  watch=${state:-not-listed}  utun=$utuns"
  sleep 20
done
