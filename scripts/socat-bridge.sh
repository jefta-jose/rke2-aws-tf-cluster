#!/usr/bin/env bash
set -e

PORT=30080

# Find the current IP of the RKE2 server VM
SERVER_IP=$(virsh -c qemu:///system domifaddr rock-server \
  | awk '/ipv4/ {print $4}' \
  | cut -d/ -f1)

if [ -z "$SERVER_IP" ]; then
  echo "Could not find rock-server IP"
  exit 1
fi

# Stop any existing bridge
pkill -f "socat.*TCP-LISTEN:$PORT" 2>/dev/null || true

# Create the bridge
nohup socat \
  TCP-LISTEN:$PORT,fork,reuseaddr \
  TCP:$SERVER_IP:$PORT \
  >/dev/null 2>&1 &

echo "Bridge started:"
echo "localhost:$PORT -> $SERVER_IP:$PORT"