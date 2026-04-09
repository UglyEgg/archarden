# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Network/listener detection helpers extracted from lib/steps.sh.
# This module intentionally contains only side-effect-free inspectors (or DRY-RUN aware probes).

net_detect::wait_for_local_tcp_listen() {
  # Purpose: Wait for local tcp listen.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # wait_for_local_tcp_listen <ip> <port> <timeout_seconds> <label>
    local ip="$1" port="$2" timeout_s="$3" label="$4"
    local i

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would wait for ${label} to listen on ${ip}:${port}"
        return 0
    fi

    for ((i=0; i<timeout_s; i++)); do
        if ss -H -lnpt 2>/dev/null | awk '{print $4}' | grep -Fq "${ip}:${port}"; then
            return 0
        fi
        sleep 1
    done

    utils::log_warn "Timeout waiting for ${label} to listen on ${ip}:${port}. Socket proxies may still work once the backend settles."
    return 1
}
net_detect::status_report() {
  # Purpose: Status report.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "==== STATUS REPORT ===="
    steps::status_cmd ss -tulnp
    if utils::have_cmd ufw; then
        steps::status_cmd ufw status verbose
    fi
    if systemctl list-unit-files --type=service | grep -q fail2ban.service; then
        steps::status_cmd systemctl status fail2ban --no-pager
    fi
    system::report_services
    if [[ ${#BACKUP_PATHS[@]} -gt 0 ]]; then
        utils::log_info "Backups created: ${BACKUP_PATHS[*]}"
    fi
}
net_detect::ip_list_contains() {
  # Purpose: Ip list contains.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local needle="$1"; shift
    local item
    for item in "$@"; do
        if [[ "${item}" == "${needle}" ]]; then
            return 0
        fi
    done
    return 1
}
net_detect::extract_ip_port() {
  # Purpose: Extract ip port.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Input forms from ss:
  #   0.0.0.0:80
  #   203.0.113.10:22
  #   [::]:443
  #   [2001:db8::1]:53
  #   *:80
    local addr="$1"
    local ip port
    if [[ "${addr}" == *"]:"* ]]; then
        ip="${addr%%]:*}"
        ip="${ip#[}"
        port="${addr##*:}"
    else
        ip="${addr%:*}"
        port="${addr##*:}"
    fi
    ip="${ip%%\%*}" # strip interface zone
    printf '%s\t%s' "${ip}" "${port}"
}
net_detect::collect_listeners() {
  # Purpose: Collect listeners.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local proto="$1"
    local -n out_ref=$2
    out_ref=()

    if ! utils::have_cmd ss; then
        return 0
    fi
    if [[ "${proto}" == "tcp" ]]; then
        # shellcheck disable=SC2034
        mapfile -t out_ref < <(ss -H -lntp 2>/dev/null | awk '{print $4}' | sort -u)
    elif [[ "${proto}" == "udp" ]]; then
        # shellcheck disable=SC2034
        mapfile -t out_ref < <(ss -H -lnup 2>/dev/null | awk '{print $4}' | sort -u)
    fi
}
net_detect::__has_localhost_tcp_listener() {
  # Purpose: Has localhost tcp listener.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local port="$1"
    local -n listeners_ref=$2
    local addr
    for addr in "${listeners_ref[@]}"; do
        if [[ "${addr}" == "127.0.0.1:${port}" || "${addr}" == "[::1]:${port}" ]]; then
            return 0
        fi
    done
    return 1
}
net_detect::diagnose_socket_proxy_backends() {
  # Purpose: Diagnose socket proxy backends.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # shellcheck disable=SC2034
    local -n tcp_listeners_ref=$1
    if ! utils::have_cmd systemctl; then
        return 0
    fi

    local -a checks=()
    checks+=("8080:archarden-http.socket:NPM public HTTP backend (127.0.0.1:8080)")
    checks+=("8443:archarden-https.socket:NPM public HTTPS backend (127.0.0.1:8443)")
    checks+=("${NPM_ADMIN_BACKEND_PORT:-8181}:archarden-npm-admin.socket:NPM admin backend (127.0.0.1:${NPM_ADMIN_BACKEND_PORT:-8181})")
    checks+=("3001:archarden-kuma.socket:Uptime Kuma backend (127.0.0.1:3001)")

    local item port unit desc
    for item in "${checks[@]}"; do
        port="${item%%:*}"
        unit="${item#*:}"; unit="${unit%%:*}"
        desc="${item#*:*:}"

        if ! systemctl is-enabled "${unit}" >/dev/null 2>&1; then
            utils::log_warn "Socket proxy is not enabled: ${unit} (${desc})"
            continue
        fi
        if ! systemctl is-active "${unit}" >/dev/null 2>&1; then
            utils::log_warn "Socket proxy is not active: ${unit} (${desc})"
        fi
        if ! net_detect::__has_localhost_tcp_listener "${port}" tcp_listeners_ref; then
            utils::log_warn "Socket proxy backend not listening: expected 127.0.0.1:${port} (${desc})"
            utils::log_warn "Hint: systemctl --user --machine=${PODMAN_USER}@.host status nginx-proxy-manager.service ntfy.service uptime-kuma.service"
            utils::log_warn "Hint: runuser -u ${PODMAN_USER} -- podman ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'"
        fi
    done
}
net_detect::__is_public_listener() {
  # Purpose: Is public listener.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local ip="$1"; shift
    local -a global_v4=("$1"); shift || true
    local -a global_v6=("$1"); shift || true

    # Note: arrays are passed by value via a single element above; this helper is not used.
    # Kept for future refactoring.
    return 1
}
