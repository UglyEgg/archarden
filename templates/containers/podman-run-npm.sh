#!/usr/bin/env bash
set -euo pipefail

# Example rootless Podman run for Nginx Proxy Manager.
# Admin UI is bound to localhost to avoid exposure; use SSH tunnel to access 8181.
podman run -d \
  --name npm \
  --restart unless-stopped \
  -p 80:80 \
  -p 443:443 \
  -p 127.0.0.1:8181:81 \
  -v npm-data:/data \
  -v npm-letsencrypt:/etc/letsencrypt \
  docker.io/jc21/nginx-proxy-manager:latest
