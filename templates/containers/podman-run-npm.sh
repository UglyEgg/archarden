#!/usr/bin/env bash
set -euo pipefail

# Example rootless Podman run for Nginx Proxy Manager.
# Admin UI is bound to localhost to avoid exposure; use SSH tunnel to access 8181.
podman run -d \
  --name npm \
  --restart unless-stopped \
  -p 127.0.0.1:8080:80 \
  -p 127.0.0.1:8443:443 \
  -p 127.0.0.1:8181:81 \
  --memory=512m \
  --pids-limit=512 \
  --memory-swap=1g \
  -v npm-data:/data \
  -v npm-letsencrypt:/etc/letsencrypt \
  docker.io/jc21/nginx-proxy-manager:latest
