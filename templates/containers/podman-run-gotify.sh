#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski
set -euo pipefail

image="gotify/server:2.4.0"
name="gotify"
data_volume="gotify-data"
host_port="8090"

if ! command -v podman >/dev/null 2>&1; then
  echo "podman is required" >&2
  exit 1
fi

podman run -d \
  --name "${name}" \
  --replace \
  --tz=UTC \
  -p "127.0.0.1:${host_port}:80/tcp" \
  -v "${data_volume}:/app/data" \
  --health-cmd "wget -q --spider http://127.0.0.1:80/health || exit 1" \
  --health-interval 30s \
  --health-retries 5 \
  --health-start-period 20s \
  --health-timeout 5s \
  --security-opt "no-new-privileges=true" \
  --cap-drop all \
  --restart=on-failure \
  "${image}"

echo "Gotify started at http://127.0.0.1:${host_port}"
