#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Read-only diagnostics for an archarden host.
#
# This library is sourced under `set -euo pipefail`.
# Doctor mode must not mutate the system.

DOCTOR_VERBOSE=${DOCTOR_VERBOSE:-0}
DOCTOR_SILENT=${DOCTOR_SILENT:-0}
DOCTOR_RESULTS=()
DOCTOR_FAILS=0
DOCTOR_WARNS=0
DOCTOR_LAST_OUT=""


doctor::__record() {
  # Purpose: Record.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Usage: doctor::__record <STATUS> <MESSAGE>
    local status="$1"; shift
    local msg="$*"
    DOCTOR_RESULTS+=("${status}|${msg}")
}

doctor::__info() {
  # Purpose: Info.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DOCTOR_SILENT} -eq 0 ]]; then
        utils::log_info "$@"
    fi
}


doctor::__section() {
  # Purpose: Section.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local title="$1"
    if [[ ${DOCTOR_SILENT} -eq 1 ]]; then
        return 0
    fi
    echo
    echo "== ${title} =="
}


doctor::__ok() {
  # Purpose: Ok.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    doctor::__record "OK" "$*"
    if [[ ${DOCTOR_SILENT} -eq 0 ]]; then
        echo "[OK]   $*"
    fi
}


doctor::__warn() {
  # Purpose: Warn.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    DOCTOR_WARNS=$((DOCTOR_WARNS + 1))
    doctor::__record "WARN" "$*"
    if [[ ${DOCTOR_SILENT} -eq 0 ]]; then
        echo "[WARN] $*"
    fi
}


doctor::__fail() {
  # Purpose: Fail.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
    doctor::__record "FAIL" "$*"
    if [[ ${DOCTOR_SILENT} -eq 0 ]]; then
        echo "[FAIL] $*"
    fi
}


doctor::__fix() {
  # Purpose: Fix.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local msg="$1"
    doctor::__record "FIX" "Fix: ${msg}"
    if [[ ${DOCTOR_SILENT} -eq 0 ]]; then
        echo "       Fix: ${msg}"
    fi
}

doctor::__run_capture() {
  # Purpose: Run capture.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Usage: doctor::__run_capture <cmd...>
    local out rc
    set +e
    out="$("$@" 2>&1)"
    rc=$?
    set -e
    DOCTOR_LAST_OUT="${out}"
    return ${rc}
}


doctor::__maybe_show_output() {
  # Purpose: Maybe show output.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DOCTOR_SILENT} -eq 1 ]]; then
        return 0
    fi
    local out="${DOCTOR_LAST_OUT:-}"
    if [[ ${DOCTOR_VERBOSE} -eq 1 && -n "${out}" ]]; then
        echo "       Output:"
        # shellcheck disable=SC2001
        echo "${out}" | sed 's/^/         /'
    fi
}

doctor::__check_file() {
  # Purpose: Check file.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local path="$1" desc="$2" fix="$3"
    if [[ -f "${path}" ]]; then
        doctor::__ok "${desc}: ${path}"
        return 0
    fi
    doctor::__fail "${desc}: missing (${path})"
    [[ -n "${fix}" ]] && doctor::__fix "${fix}"
    return 1
}

doctor::__check_service_active() {
  # Purpose: Check service active.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local unit="$1" fix="$2"
    if ! utils::have_cmd systemctl; then
        doctor::__warn "systemctl not available; cannot check ${unit}"
        return 0
    fi

    # Distinguish "inactive" from "not installed" so we don't suggest nonsense fixes.
    if doctor::__run_capture systemctl show -p LoadState --value "${unit}"; then
        local loadstate="${DOCTOR_LAST_OUT//$'\n'/}"
        if [[ "${loadstate}" == "not-found" ]]; then
            doctor::__fail "${unit}: missing (not installed)"
            doctor::__fix "Re-run: archarden apply (phase1) to install archarden systemd units"
            doctor::__maybe_show_output
            return 1
        fi
    fi

    if doctor::__run_capture systemctl is-active "${unit}"; then
        doctor::__ok "${unit}: active"
        return 0
    fi

    local state
    state="${DOCTOR_LAST_OUT//$'\n'/ }"
    doctor::__fail "${unit}: not active (${state:-unknown})"
    [[ -n "${fix}" ]] && doctor::__fix "${fix}"
    doctor::__maybe_show_output
    return 1
}

doctor::__check_service_enabled() {
  # Purpose: Check service enabled.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local unit="$1" fix="$2"
    if ! utils::have_cmd systemctl; then
        doctor::__warn "systemctl not available; cannot check enablement for ${unit}"
        return 0
    fi

    if doctor::__run_capture systemctl is-enabled "${unit}"; then
        doctor::__ok "${unit}: enabled"
        return 0
    fi

    local state
    state="${DOCTOR_LAST_OUT//$'\n'/ }"
    doctor::__warn "${unit}: not enabled (${state:-unknown})"
    [[ -n "${fix}" ]] && doctor::__fix "${fix}"
    doctor::__maybe_show_output
    return 0
}

doctor::__check_listener_absent() {
  # Purpose: Check listener absent.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local pattern="$1" desc="$2" fix="$3"
    if ! utils::have_cmd ss; then
        doctor::__warn "ss not available; cannot check listeners"
        return 0
    fi

    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE "${pattern}"; then
        doctor::__fail "${desc}: listener present"
        [[ -n "${fix}" ]] && doctor::__fix "${fix}"
        return 1
    fi

    doctor::__ok "${desc}: not listening"
    return 0
}

doctor::__check_listener_present() {
  # Purpose: Check listener present.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local pattern="$1" desc="$2" fix="$3"
    if ! utils::have_cmd ss; then
        doctor::__warn "ss not available; cannot check listeners"
        return 0
    fi

    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE "${pattern}"; then
        doctor::__ok "${desc}: listening"
        return 0
    fi

    doctor::__fail "${desc}: not listening"
    [[ -n "${fix}" ]] && doctor::__fix "${fix}"
    return 1
}

doctor::__read_wireguard_conf_value() {
  # Purpose: Read wireguard conf value.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local key="$1" file="$2"
    if [[ ! -f "${file}" ]]; then
        return 1
    fi
    grep -E "^${key}[[:space:]]*=" "${file}" 2>/dev/null | head -n1 | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}'
}

doctor::__podmin_context() {
  # Purpose: Podmin context.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Prints: <uid> <home>
    local uid home
    uid=""
    home=""
    if getent passwd podmin >/dev/null 2>&1; then
        uid=$(id -u podmin 2>/dev/null || true)
        home=$(getent passwd podmin | cut -d: -f6)
    fi
    if [[ -z "${home}" ]]; then
        home="/home/podmin"
    fi
    echo "${uid} ${home}"
}

doctor::__podmin_systemctl() {
  # Purpose: Podmin systemctl.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Usage: doctor::__podmin_systemctl <uid> <args...>
    local uid="$1"; shift
    if ! utils::have_cmd systemctl; then
        return 127
    fi

    set +e
    systemctl --user --machine="podmin@.host" "$@" >/dev/null 2>&1
    local rc=$?
    set -e

    if [[ ${rc} -eq 0 ]]; then
        return 0
    fi

    # Fallback: talk to the user bus directly if present.
    local runtime_dir="/run/user/${uid}"
    if [[ -S "${runtime_dir}/bus" ]] && utils::have_cmd runuser; then
        set +e
        XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
            runuser -u podmin -- systemctl --user "$@" >/dev/null 2>&1
        rc=$?
        set -e
        return ${rc}
    fi

    return ${rc}
}

doctor::__check_podmin_user_service_active() {
  # Purpose: Check podmin user service active.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local uid="$1" service="$2" fix="$3"
    if [[ -z "${uid}" ]]; then
        doctor::__fail "podmin user missing; cannot check ${service}"
        [[ -n "${fix}" ]] && doctor::__fix "${fix}"
        return 1
    fi

    if doctor::__podmin_systemctl "${uid}" is-active "${service}"; then
        doctor::__ok "podmin:${service}: active"
        return 0
    fi

    doctor::__fail "podmin:${service}: not active"
    [[ -n "${fix}" ]] && doctor::__fix "${fix}"

    if [[ -S "/run/user/${uid}/bus" ]]; then
        doctor::__warn "podmin user bus exists, but systemctl check failed; inspect: journalctl --user -u ${service}"
    else
        doctor::__warn "podmin user bus missing at /run/user/${uid}/bus"
        doctor::__fix "Enable linger and user manager: loginctl enable-linger podmin && systemctl start user@${uid}.service"
    fi

    return 1
}

doctor::__check_podman_ps() {
  # Purpose: Check podman ps.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local uid="$1" home="$2"
    if ! utils::have_cmd podman; then
        doctor::__fail "podman not installed"
        doctor::__fix "pacman -S podman"
        return 1
    fi

    if ! utils::have_cmd runuser; then
        doctor::__warn "runuser not available; cannot run podman ps as podmin"
        return 0
    fi

    local runtime_dir="/run/user/${uid}"
    if [[ -z "${uid}" ]]; then
        doctor::__fail "podmin user missing; cannot inspect containers"
        return 1
    fi

    set +e
    local out
    out=$(runuser -u podmin -- bash -lc "cd \"${home}\" && env HOME=\"${home}\" XDG_RUNTIME_DIR=\"${runtime_dir}\" podman ps --format '{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}'" 2>&1)
    local rc=$?
    set -e

    if [[ ${rc} -ne 0 ]]; then
        doctor::__fail "podman ps (as podmin) failed"
        # shellcheck disable=SC2001
        echo "${out}" | sed 's/^/       /'
        return 1
    fi

    doctor::__ok "podman ps (as podmin) succeeded"

    if [[ ${DOCTOR_VERBOSE} -eq 1 ]]; then
        echo "       Containers:"
        # shellcheck disable=SC2001
        echo "${out}" | sed 's/^/         /'
    fi

    # Basic foot-gun checks: make sure expected ports are loopback-only.
    if echo "${out}" | grep -qE '0\.0\.0\.0:8080->80'; then
        doctor::__fail "NPM HTTP appears to be bound publicly (0.0.0.0:8080)"
        doctor::__fix "Bind NPM ports to 127.0.0.1 and front them with socket-proxyd (re-run archarden phase 1)"
    fi
    if echo "${out}" | grep -qE '0\.0\.0\.0:8443->443'; then
        doctor::__fail "NPM HTTPS appears to be bound publicly (0.0.0.0:8443)"
        doctor::__fix "Bind NPM ports to 127.0.0.1 and front them with socket-proxyd (re-run archarden phase 1)"
    fi
    if echo "${out}" | grep -qE '0\.0\.0\.0:3001->3001'; then
        doctor::__fail "Uptime Kuma appears to be bound publicly (0.0.0.0:3001)"
        doctor::__fix "Bind Kuma to 127.0.0.1 and expose via wg0 socket-proxyd (re-run archarden phase 1)"
    fi

    return 0
}

doctor::__check_npm_api() {
  # Purpose: Check npm api.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -z "${NPM_ADMIN_PORT:-}" ]]; then
        doctor::__warn "NPM_ADMIN_PORT not set; cannot probe NPM API"
        return 0
    fi

    if ! utils::have_cmd curl; then
        doctor::__warn "curl not available; cannot probe NPM API"
        return 0
    fi

    local url="http://127.0.0.1:${NPM_ADMIN_PORT}/api/schema"

    if doctor::__run_capture curl -fsS --max-time 5 "${url}"; then
        doctor::__ok "NPM API reachable on loopback (${url})"
        return 0
    fi

    doctor::__fail "NPM API not reachable on loopback (${url})"
    doctor::__fix "Check nginx-proxy-manager.service under podmin and ensure socket proxies are active"
    doctor::__maybe_show_output
    return 1
}

doctor::__check_phase2_creds() {
  # Purpose: Check phase2 creds.
    local secrets_dir="${STATE_DIR:-/var/lib/archarden}/secrets"
    local npm_pass="${secrets_dir}/npm_admin_pass"

    if [[ -f "${npm_pass}" ]]; then
        doctor::__ok "NPM admin password secret present (${npm_pass})"
    else
        doctor::__warn "NPM admin password secret missing (${npm_pass})"
        doctor::__fix "Run: sudo ./archarden creds --npm-admin-email <you@domain>"
    fi
}


doctor::__check_notify_env() {
  # Purpose: Check notification env.
    local env_file="/etc/archarden/notify.env"
    if [[ -f "${env_file}" ]]; then
        # shellcheck disable=SC1090
        source "${env_file}"
        if [[ -z "${NTFY_URL:-}" || -z "${NTFY_TOPIC:-}" ]]; then
            doctor::__warn "ntfy notify env present but missing NTFY_URL or NTFY_TOPIC"
            doctor::__fix "Run: sudo ./archarden notify init --backend ntfy --test"
        elif [[ -z "${NTFY_TOKEN:-}" && -z "${NTFY_USER:-}" ]]; then
            doctor::__warn "ntfy notify env present but missing publisher credentials (NTFY_TOKEN or NTFY_USER/NTFY_PASS)"
            doctor::__fix "Run: sudo ./archarden notify init --backend ntfy --test"
        else
            doctor::__ok "ntfy notify env configured (${env_file})"
        fi
        return 0
    fi
    doctor::__warn "Notification env not found (/etc/archarden/notify.env)"
    doctor::__fix "Run: sudo ./archarden notify init --backend ntfy --test"
    return 0
}


doctor::__check_dnsmasq_wg0_conf() {
  # Purpose: Check dnsmasq wg0 conf.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local conf_file="/etc/dnsmasq.d/archarden-wg0.conf"
    if [[ ! -f "${conf_file}" ]]; then
        doctor::__warn "dnsmasq wg0 config missing (${conf_file})"
        doctor::__fix "Re-run phase 1 to install dnsmasq and generate wg0 DNS config"
        return 0
    fi

    if grep -qx "interface=wg0" "${conf_file}" && grep -qx "bind-dynamic" "${conf_file}"; then
        doctor::__ok "dnsmasq configured for wg0 only"
        return 0
    fi

    doctor::__warn "dnsmasq wg0 config present but does not look like the managed template"
    doctor::__fix "Inspect ${conf_file} for interface=wg0 and bind-dynamic"
    return 0
}

doctor::__check_lockdown_state() {
  # Purpose: Check lockdown state.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local marker_file="${LOCKDOWN_MARKER_FILE:-/var/lib/archarden/lockdown.done}"
    if [[ -f "${marker_file}" ]]; then
        doctor::__ok "Lockdown marker present (${marker_file})"
        return 0
    fi

    doctor::__warn "Lockdown marker not present (${marker_file})"
    doctor::__fix "After VPN verified: sudo ${INSTALL_BIN} lockdown"
    return 0
}

doctor::__check_sshd_binding() {
  # Purpose: Check sshd binding.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local ssh_port="${SSH_PORT:-22}"
    local wg_ip=""

    if [[ -n "${WG_INTERFACE_ADDRESS:-}" ]]; then
        wg_ip="${WG_INTERFACE_ADDRESS%%/*}"
    elif utils::have_cmd ip; then
        wg_ip=$(ip -o -4 addr show dev wg0 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -n1 || true)
    fi

    if ! utils::have_cmd ss; then
        doctor::__warn "ss not available; cannot check sshd listeners"
        return 0
    fi

    # If sshd is disabled or stopped, that's acceptable in VPN-only deployments.
    if utils::have_cmd systemctl && ! systemctl is-active sshd >/dev/null 2>&1; then
        doctor::__ok "sshd: not active"
        return 0
    fi

    # If wg-only drop-in exists, expect sshd to be bound to the wg0 address.
    if [[ -n "${wg_ip}" ]]; then
        if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qx "${wg_ip}:${ssh_port}"; then
            doctor::__ok "sshd listening on wg0 only (${wg_ip}:${ssh_port})"
            return 0
        fi
    fi

    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE "(0\.0\.0\.0|\[::\]|::):${ssh_port}\b"; then
        doctor::__warn "sshd appears to be listening on a wildcard address for port ${ssh_port}"
        doctor::__fix "If VPN verified: sudo ${INSTALL_BIN} lockdown (bind sshd to wg0)"
        return 0
    fi

    doctor::__ok "sshd listener not detected on wildcard addresses"
    return 0
}

doctor::__check_security_posture() {
  # Purpose: Check security posture.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    doctor::__section "Public exposure"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        doctor::__ok "[DRY-RUN] Would run verify::security_posture"
        return 0
    fi

    if ! declare -F verify::security_posture >/dev/null 2>&1; then
        doctor::__warn "verify::security_posture not available"
        return 0
    fi

    local out rc
    set +e
    out=$(verify::security_posture 2>&1)
    rc=$?
    set -e

    if [[ ${rc} -eq 0 ]]; then
        doctor::__ok "verify::security_posture: passed"
        if [[ ${DOCTOR_VERBOSE} -eq 1 ]]; then
            # shellcheck disable=SC2001
            echo "${out}" | sed 's/^/       /'
        fi
        return 0
    fi

    doctor::__fail "verify::security_posture: failed"
    # shellcheck disable=SC2001
    echo "${out}" | sed 's/^/       /'
    return 1
}

doctor::__check_timers() {
  # Purpose: Check timers.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    doctor::__section "Update notifications"

    doctor::__check_service_enabled archarden-os-report.timer "systemctl enable --now archarden-os-report.timer"
    doctor::__check_service_enabled archarden-container-scan.timer "systemctl enable --now archarden-container-scan.timer"

    doctor::__check_service_active archarden-os-report.timer "systemctl enable --now archarden-os-report.timer"
    doctor::__check_service_active archarden-container-scan.timer "systemctl enable --now archarden-container-scan.timer"

    doctor::__check_file /usr/lib/archarden/notify_send.sh "Notification sender script" "Re-run phase 1 notification provisioning"
    doctor::__check_file /usr/lib/archarden/container_update_scan.sh "Container scan script" "Re-run phase 1 notification provisioning"
}

doctor::__print_dry_run_plan() {
  # Purpose: Print dry run plan.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    cat <<'EOT'
Doctor (dry-run): would perform read-only checks

- WireGuard: wg0 interface, wg-quick@wg0 status, ListenPort, key files, client configs
- DNS: dnsmasq configuration for wg0 and service status
- Socket proxies: archarden-http/https, archarden-npm-admin, archarden-kuma sockets and listeners
- Rootless Podman: podmin user manager, systemd user services, podman ps, port bindings
- NPM: API reachability on loopback (127.0.0.1:<admin-port>)
- ntfy: notify env/topic and systemd timers for update scans
- SSH/Lockdown: lockdown marker and sshd listener binding
- Exposure: run verify::security_posture (no unexpected public listeners)
EOT
}

# Public entrypoint used by `archarden doctor`
doctor::run() {
  # Purpose: Run the requested state. (systemd)
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    doctor::__info "==== ARCHARDEN DOCTOR ===="

    DOCTOR_RESULTS=()
    DOCTOR_FAILS=0
    DOCTOR_WARNS=0

    if [[ ${DRY_RUN} -eq 1 ]]; then
        doctor::__record "OK" "Doctor (dry-run): no checks executed"
        if [[ ${DOCTOR_SILENT} -eq 0 ]]; then
            doctor::__print_dry_run_plan
        fi
        return 0
    fi

    doctor::__section "Host" 
    doctor::__ok "hostname: $(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    doctor::__ok "kernel: $(uname -r 2>/dev/null || echo unknown)"

    doctor::__section "WireGuard" 

    doctor::__check_file /etc/wireguard/wg0.conf "wg0 config" "Ensure /etc/wireguard/wg0.conf exists (re-run phase 1 wireguard step)"
    doctor::__check_file /etc/wireguard/keys/server.key "WireGuard server private key" "Re-run phase 1 wireguard step"
    doctor::__check_file /etc/wireguard/keys/server.pub "WireGuard server public key" "Re-run phase 1 wireguard step"

    if utils::have_cmd ip; then
        if doctor::__run_capture ip link show wg0; then
            doctor::__ok "wg0 interface exists"
        else
            doctor::__fail "wg0 interface missing"
            doctor::__fix "systemctl enable --now wg-quick@wg0.service"
            doctor::__maybe_show_output
        fi
    else
        doctor::__warn "ip command not found; cannot inspect wg0"
    fi

    doctor::__check_service_active wg-quick@wg0.service "systemctl enable --now wg-quick@wg0.service"

    local wg_listen=""
    wg_listen=$(doctor::__read_wireguard_conf_value ListenPort /etc/wireguard/wg0.conf 2>/dev/null || true)
    if [[ -n "${wg_listen}" ]]; then
        doctor::__ok "wg0 ListenPort: ${wg_listen}"
    else
        doctor::__warn "Could not read ListenPort from /etc/wireguard/wg0.conf"
    fi

    if [[ -d "${STATE_DIR}/wireguard/clients" ]]; then
        local client_count
        client_count=$(find "${STATE_DIR}/wireguard/clients" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | wc -l | awk '{print $1}')
        doctor::__ok "WireGuard client configs: ${client_count} under ${STATE_DIR}/wireguard/clients"
        if [[ ${client_count} -eq 0 ]]; then
            doctor::__warn "No WireGuard client configs found"
            doctor::__fix "Run: sudo ${INSTALL_BIN} wg export"
        fi
    else
        doctor::__warn "WireGuard client config directory missing (${STATE_DIR}/wireguard/clients)"
        doctor::__fix "Run: sudo ${INSTALL_BIN} wg export"
    fi

    doctor::__section "DNS (wg-only)" 
    doctor::__check_dnsmasq_wg0_conf
    doctor::__check_service_active dnsmasq.service "systemctl enable --now dnsmasq.service"

    # Basic DNS listener: dnsmasq should listen on wg0 address. This is best-effort.
    if [[ -n "${WG_INTERFACE_ADDRESS:-}" ]]; then
        local wg_ip
        wg_ip="${WG_INTERFACE_ADDRESS%%/*}"
        if [[ -n "${wg_ip}" ]]; then
            doctor::__check_listener_present "${wg_ip}:53\b" "dnsmasq on ${wg_ip}:53" "Check dnsmasq.service and /etc/dnsmasq.d/archarden-wg0.conf"
        fi
    fi

    doctor::__section "Firewall" 
    if utils::have_cmd ufw; then
        if ufw status 2>/dev/null | head -n1 | grep -qi 'active'; then
            doctor::__ok "ufw: active"
        else
            doctor::__fail "ufw: not active"
            doctor::__fix "ufw enable && systemctl enable --now ufw"
        fi

        if ufw status verbose 2>/dev/null | grep -qiE '^Default:.*deny \(incoming\)'; then
            doctor::__ok "ufw default incoming: deny"
        else
            doctor::__warn "ufw default incoming is not deny"
            doctor::__fix "Review: ufw status verbose"
        fi
    else
        doctor::__fail "ufw not installed"
        doctor::__fix "pacman -S ufw && systemctl enable --now ufw"
    fi

    doctor::__section "Socket proxies" 
    doctor::__check_service_active archarden-http.socket "systemctl enable --now archarden-http.socket"
    doctor::__check_service_active archarden-https.socket "systemctl enable --now archarden-https.socket"
    doctor::__check_service_active archarden-npm-admin.socket "systemctl enable --now archarden-npm-admin.socket"
    doctor::__check_service_active archarden-kuma.socket "systemctl enable --now archarden-kuma.socket"

    doctor::__check_listener_present ":80\b" "public HTTP (port 80)" "Check archarden-http.socket"
    doctor::__check_listener_present ":443\b" "public HTTPS (port 443)" "Check archarden-https.socket"

    # Admin exposure checks.
    doctor::__check_listener_absent "(0\.0\.0\.0|\[::\]|::):${NPM_ADMIN_PORT:-81}\b" "NPM admin public" "Ensure NPM admin is only reachable over wg0 socket proxy"
    doctor::__check_listener_absent "(0\.0\.0\.0|\[::\]|::):3001\b" "Uptime Kuma public" "Ensure Kuma is only reachable over wg0 socket proxy"

    doctor::__section "Rootless Podman" 
    local ctx uid home
    ctx=$(doctor::__podmin_context)
    uid="${ctx%% *}"
    home="${ctx#* }"

    if [[ -z "${uid}" ]]; then
        doctor::__fail "podmin user missing"
        doctor::__fix "Re-run phase 1; podmin is required for rootless containers"
    else
        doctor::__ok "podmin uid: ${uid} home: ${home}"
    fi

    doctor::__check_podmin_user_service_active "${uid}" nginx-proxy-manager.service "Check podmin user services and container logs"
        doctor::__check_podmin_user_service_active "${uid}" ntfy.service "Check podmin user services and container logs"
    doctor::__check_podmin_user_service_active "${uid}" uptime-kuma.service "Check podmin user services and container logs"
    doctor::__check_podman_ps "${uid}" "${home}"

    doctor::__section "NPM" 
    doctor::__check_npm_api

    doctor::__section "Notifications" 
    doctor::__check_notify_env
    doctor::__check_timers

    doctor::__section "SSH/Lockdown" 
    doctor::__check_lockdown_state
    doctor::__check_sshd_binding

    doctor::__check_security_posture

    if [[ ${DOCTOR_SILENT} -eq 0 ]]; then
        echo
        if [[ ${DOCTOR_FAILS} -eq 0 && ${DOCTOR_WARNS} -eq 0 ]]; then
            echo "Doctor result: clean"
        else
            echo "Doctor result: fails=${DOCTOR_FAILS} warns=${DOCTOR_WARNS}"
        fi
    fi

    if [[ ${DOCTOR_FAILS} -gt 0 ]]; then
        return 1
    fi
    return 0
}


doctor::__json_escape() {
  # Purpose: Json escape.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local s="$*"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "${s}"
}

doctor::__emit_json() {
  # Purpose: Emit json.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local version host ts status
    version="$(show_version 2>/dev/null || echo unknown)"
    host="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if [[ ${DOCTOR_FAILS} -gt 0 ]]; then
        status="fail"
    elif [[ ${DOCTOR_WARNS} -gt 0 ]]; then
        status="warn"
    else
        status="ok"
    fi

    printf '{'
    printf '"tool":"archarden-doctor",'
    printf '"version":"%s",' "$(doctor::__json_escape "${version}")"
    printf '"timestamp_utc":"%s",' "$(doctor::__json_escape "${ts}")"
    printf '"hostname":"%s",' "$(doctor::__json_escape "${host}")"
    printf '"status":"%s",' "$(doctor::__json_escape "${status}")"
    printf '"fails":%s,' "${DOCTOR_FAILS}"
    printf '"warns":%s,' "${DOCTOR_WARNS}"
    printf '"results":['
    local first=1 entry st msg
    for entry in "${DOCTOR_RESULTS[@]}"; do
        st="${entry%%|*}"
        msg="${entry#*|}"
        if [[ ${first} -eq 0 ]]; then
            printf ','
        fi
        first=0
        printf '{"status":"%s","message":"%s"}' "$(doctor::__json_escape "${st}")" "$(doctor::__json_escape "${msg}")"
    done
    printf ']'
    printf '}\n'
}

doctor::run_json() {
  # Purpose: Run json.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    DOCTOR_SILENT=1
    DOCTOR_RESULTS=()
    DOCTOR_FAILS=0
    DOCTOR_WARNS=0
    local rc=0
    set +e
    doctor::run
    rc=$?
    set -e
    doctor::__emit_json
    return ${rc}
}

doctor::__bundle_write_file() {
  # Purpose: Bundle write file.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest="$1"; shift
    local cmd=("$@")
    if [[ ${#cmd[@]} -eq 0 ]]; then
        return 0
    fi
    set +e
    "${cmd[@]}" >"${dest}" 2>&1
    local rc=$?
    set -e
    return ${rc}
}

doctor::__bundle_sanitize_file() {
  # Purpose: Bundle sanitize file.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local src="$1" dest="$2" kind="$3"
    [[ -f "${src}" ]] || return 1

    case "${kind}" in
        wireguard_conf)
            sed -E \
                -e 's/^([[:space:]]*PrivateKey[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/' \
                -e 's/^([[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*).*/\1<REDACTED>/' \
                "${src}" >"${dest}"
            ;;
        answers)
            sed -E \
                -e 's/(--npm-admin-password)[[:space:]]+[^[:space:]]+/\1 <REDACTED>/' \
                -e 's/(--pubkey)[[:space:]]+\"[^\"]+\"/\1 \"<REDACTED>\"/' \
                "${src}" >"${dest}"
            ;;
        notify_env)
            sed -E -e 's/^(NTFY_TOKEN=).*/\1<REDACTED>/' -e 's/^(NTFY_PASS=).*/\1<REDACTED>/' "${src}" >"${dest}"
            ;;
        *)
            cp -f "${src}" "${dest}"
            ;;
    esac
    return 0
}

doctor::bundle_create() {
  # Purpose: Bundle create.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local report_file="$1"
    local report_rc="$2"

    local out_dir="${DOCTOR_BUNDLE_DIR:-/var/lib/archarden/doctor}"
    local ts short_host bundle_name tmpdir rootdir cmd_dir cfg_dir

    ts="$(date -u '+%Y%m%d-%H%M%SZ')"
    short_host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)"
    bundle_name="doctor-${short_host}-${ts}.tar.gz"

    tmpdir="$(mktemp -d)"
    rootdir="${tmpdir}/bundle"
    cmd_dir="${rootdir}/cmd"
    cfg_dir="${rootdir}/config"
    install -d -m 0700 "${rootdir}" "${cmd_dir}" "${cfg_dir}"

    cp -f "${report_file}" "${rootdir}/doctor_report.txt"
    doctor::__emit_json >"${rootdir}/doctor_summary.json"

    {
        echo "timestamp_utc=${ts}"
        echo "hostname=${short_host}"
        echo "doctor_exit_code=${report_rc}"
        echo "fails=${DOCTOR_FAILS}"
        echo "warns=${DOCTOR_WARNS}"
        echo "version=$(show_version 2>/dev/null || echo unknown)"
    } >"${rootdir}/meta.txt"

    doctor::__bundle_write_file "${cmd_dir}/ss_tulpn.txt" ss -tulpn
    doctor::__bundle_write_file "${cmd_dir}/ip_addr.txt" ip addr
    doctor::__bundle_write_file "${cmd_dir}/ip_route.txt" ip route
    doctor::__bundle_write_file "${cmd_dir}/wg_show.txt" wg show
    doctor::__bundle_write_file "${cmd_dir}/ufw_status_verbose.txt" ufw status verbose
    doctor::__bundle_write_file "${cmd_dir}/systemctl_failed.txt" systemctl --failed
    doctor::__bundle_write_file "${cmd_dir}/systemctl_status_archarden_sockets.txt" systemctl status archarden-http.socket archarden-https.socket archarden-npm-admin.socket archarden-kuma.socket --no-pager
    doctor::__bundle_write_file "${cmd_dir}/systemctl_status_wg_dns.txt" systemctl status wg-quick@wg0.service dnsmasq.service --no-pager
    doctor::__bundle_write_file "${cmd_dir}/journal_archarden_sockets.txt" journalctl -u archarden-http.socket -u archarden-https.socket -u archarden-npm-admin.socket -u archarden-kuma.socket -n 200 --no-pager
    doctor::__bundle_write_file "${cmd_dir}/journal_wg_dns.txt" journalctl -u wg-quick@wg0.service -u dnsmasq.service -n 200 --no-pager

    local ctx uid home
    ctx="$(doctor::__podmin_context)"
    uid="${ctx%% *}"
    home="${ctx#* }"
    if [[ -n "${uid}" ]] && utils::have_cmd runuser; then
        local runtime_dir="/run/user/${uid}"
        doctor::__bundle_write_file "${cmd_dir}/podman_ps_podmin.txt" runuser -u podmin -- env HOME="${home}" XDG_RUNTIME_DIR="${runtime_dir}" podman ps --all
        doctor::__bundle_write_file "${cmd_dir}/podman_network_ls_podmin.txt" runuser -u podmin -- env HOME="${home}" XDG_RUNTIME_DIR="${runtime_dir}" podman network ls
        doctor::__bundle_write_file "${cmd_dir}/systemctl_user_status_podmin.txt" systemctl --user --machine="podmin@.host" status nginx-proxy-manager.service ntfy.service uptime-kuma.service --no-pager
        doctor::__bundle_write_file "${cmd_dir}/journal_user_podmin_npm.txt" journalctl --user --machine="podmin@.host" -u nginx-proxy-manager.service -n 200 --no-pager
                doctor::__bundle_write_file "${cmd_dir}/journal_user_podmin_ntfy.txt" journalctl --user --machine="podmin@.host" -u ntfy.service -n 200 --no-pager
        doctor::__bundle_write_file "${cmd_dir}/journal_user_podmin_kuma.txt" journalctl --user --machine="podmin@.host" -u uptime-kuma.service -n 200 --no-pager
    fi

    doctor::__bundle_sanitize_file "/etc/wireguard/wg0.conf" "${cfg_dir}/wg0.conf.redacted" wireguard_conf || true
    doctor::__bundle_sanitize_file "${ANSWERS_FILE:-/var/lib/archarden/answers.params}" "${cfg_dir}/answers.params.redacted" answers || true
    doctor::__bundle_sanitize_file "/etc/archarden/notify.env" "${cfg_dir}/notify.env.redacted" notify_env || true
    if [[ -f "/etc/dnsmasq.d/archarden-wg0.conf" ]]; then
        cp -f "/etc/dnsmasq.d/archarden-wg0.conf" "${cfg_dir}/dnsmasq-wg0.conf"
    fi

    {
        echo "Redaction policy:"
        echo "- WireGuard private keys and preshared keys are redacted."
        echo "- ntfy tokens and passwords are redacted."
        echo "- NPM admin password and inline pubkey are redacted from answers.params."
        echo "- /var/lib/archarden/secrets/* are NOT included."
        echo "- /etc/wireguard/keys/server.key is NOT included."
    } >"${rootdir}/REDACTIONS.txt"

    install -d -m 0700 -o root -g root "${out_dir}"
    local dest="${out_dir}/${bundle_name}"
    tar -C "${rootdir}" -czf "${dest}" .
    chmod 0600 "${dest}"

    rm -rf "${tmpdir}"

    echo "Doctor bundle written: ${dest}"
    return 0
}
