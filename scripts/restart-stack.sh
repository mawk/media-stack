#!/usr/bin/env bash
# Soft-restarts the entire media-stack (RUNBOOK.md, "1. Soft restart").
# Graceful stop + recreate via the systemd unit — try this first for any
# "a service is stuck/unresponsive" problem before reaching for a full teardown.
set -euo pipefail

echo "Restarting media-stack.service..."
sudo systemctl restart media-stack.service

echo "Waiting for containers to come up..."
sleep 5

cd /home/michaelr/media-stack
docker compose --profile vpn ps
