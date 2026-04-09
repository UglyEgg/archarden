# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# systemd socket activation + systemd-socket-proxyd provisioning.
# Extracted from lib/steps.sh to keep the orchestration layer smaller.

socket_proxy::configure() {
  # Purpose: Configure the requested state.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local vpn_ip
    vpn_ip="${WG_INTERFACE_ADDRESS%%/*}"
    if [[ -z "${vpn_ip}" ]]; then
        vpn_ip="${WIREGUARD_SERVER_IP:-10.66.66.1}"
    fi

    local http_socket=/etc/systemd/system/archarden-http.socket
    local http_service=/etc/systemd/system/archarden-http.service
    local https_socket=/etc/systemd/system/archarden-https.socket
    local https_service=/etc/systemd/system/archarden-https.service

    local npm_socket=/etc/systemd/system/archarden-npm-admin.socket
    local npm_service=/etc/systemd/system/archarden-npm-admin.service
    local kuma_socket=/etc/systemd/system/archarden-kuma.socket
    local kuma_service=/etc/systemd/system/archarden-kuma.service

    backup::file "${http_socket}"
    backup::file "${http_service}"
    backup::file "${https_socket}"
    backup::file "${https_service}"
    backup::file "${npm_socket}"
    backup::file "${npm_service}"
    backup::file "${kuma_socket}"
    backup::file "${kuma_service}"

    utils::write_file_atomic "${http_socket}" <<'EOT'
[Socket]
ListenStream=80
Accept=no

[Install]
WantedBy=sockets.target
EOT

    utils::write_file_atomic "${http_service}" <<'EOT'
[Unit]
Description=archarden HTTP socket proxy
Requires=archarden-http.socket
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:8080
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6
IPAddressDeny=any
IPAddressAllow=127.0.0.1
IPAddressAllow=::1
Restart=on-failure
RestartSec=1s
EOT

    utils::write_file_atomic "${https_socket}" <<'EOT'
[Socket]
ListenStream=443
Accept=no

[Install]
WantedBy=sockets.target
EOT

    utils::write_file_atomic "${https_service}" <<'EOT'
[Unit]
Description=archarden HTTPS socket proxy
Requires=archarden-https.socket
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:8443
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6
IPAddressDeny=any
IPAddressAllow=127.0.0.1
IPAddressAllow=::1
Restart=on-failure
RestartSec=1s
EOT

    # VPN-only admin sockets (bind to the wg0 address). These are intended for browser access
    # from WireGuard clients without exposing the underlying containers on public interfaces.

    utils::write_file_atomic "${npm_socket}" <<EOT
[Socket]
ListenStream=${vpn_ip}:${NPM_ADMIN_PORT:-81}
FreeBind=yes
Accept=no

[Install]
WantedBy=sockets.target
EOT

    utils::write_file_atomic "${npm_service}" <<EOT
[Unit]
Description=archarden NPM admin socket proxy
Requires=archarden-npm-admin.socket
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:${NPM_ADMIN_BACKEND_PORT:-8181}
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6
IPAddressDeny=any
IPAddressAllow=127.0.0.1
IPAddressAllow=::1
Restart=on-failure
RestartSec=1s
EOT

    utils::write_file_atomic "${kuma_socket}" <<EOT
[Socket]
ListenStream=${vpn_ip}:3001
FreeBind=yes
Accept=no

[Install]
WantedBy=sockets.target
EOT

    utils::write_file_atomic "${kuma_service}" <<'EOT'
[Unit]
Description=archarden Uptime Kuma socket proxy
Requires=archarden-kuma.socket
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:3001
DynamicUser=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
RestrictAddressFamilies=AF_INET AF_INET6
IPAddressDeny=any
IPAddressAllow=127.0.0.1
IPAddressAllow=::1
Restart=on-failure
RestartSec=1s
EOT

    systemd::daemon_reload
    systemd::enable_now archarden-http.socket archarden-https.socket archarden-npm-admin.socket archarden-kuma.socket
}
