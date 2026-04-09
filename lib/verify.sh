# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Verification helpers extracted from lib/steps.sh.
# These are called by steps orchestration and by the CLI `verify` subcommand.

verify::quadlet_status() {
  # Purpose: Report status for quadlet.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local service="$1"
    if ! podman_runtime::ensure_podmin_user_manager; then
        utils::log_warn "User manager unavailable for ${PODMAN_USER}; skipping quadlet management."
        return
    fi
    if podman_runtime::podmin_systemctl status "${service}" --no-pager; then
        return 0
    fi
    utils::log_warn "Status check failed for ${service}; inspecting generated units"
    utils::run_cmd "systemctl --user --machine=${PODMAN_USER}@.host list-unit-files --no-pager | grep -E 'nginx-proxy-manager|ntfy' || true"
    utils::run_cmd "ls -la /run/user/${PODMAN_UID}/systemd/generator/ | grep -E 'nginx-proxy-manager|ntfy' || true"
}

verify::podman_runtime() {
  # Purpose: Podman runtime.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local runtime_output rc=0
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would verify Podman runtime as ${PODMAN_USER}"
        return
    fi
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping Podman runtime verification because prerequisites were not satisfied."
        return
    fi
    runtime_output=$(podman_runtime::podmin_podman_info) || rc=$?
    rc=${rc:-0}
    runtime_output=$(echo "${runtime_output:-}" | tr -d '\r')
    if [[ ${rc} -ne 0 || -z "${runtime_output}" ]]; then
        utils::log_warn "Podman runtime check failed for ${PODMAN_USER}; see earlier errors."
        return
    fi
    if [[ "${runtime_output}" != "runc" ]]; then
        utils::log_warn "Podman runtime reported '${runtime_output}' for ${PODMAN_USER}; expected 'runc'. Ensure containers.conf is applied."
    else
        utils::log_info "Podman runtime verified as '${runtime_output}' for ${PODMAN_USER}"
    fi
}

verify::security_posture() {
  # Purpose: Security posture.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "==== SECURITY POSTURE VERIFICATION ===="
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would verify public listeners and UFW state"
        return
    fi

    local lockdown_active=0
    if [[ -f "${LOCKDOWN_MARKER_FILE}" ]]; then
        lockdown_active=1
    fi

    local -a global_v4=() global_v6=()
    steps::collect_global_addrs global_v4 global_v6

    # Treat WireGuard listeners as non-public for the purpose of exposure checks.
    # `ip addr ... scope global` will typically include wg0 addresses, but those are intentionally
    # reachable only to VPN peers.
    local wg_ip4=""
    if [[ -n "${WG_INTERFACE_ADDRESS:-}" ]]; then
        wg_ip4="${WG_INTERFACE_ADDRESS%%/*}"
    elif utils::have_cmd ip; then
        wg_ip4=$(ip -o -4 addr show dev wg0 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -n1 || true)
    fi

    local -a allowed_tcp=(80 443)
    local -a allowed_udp=()
    local wg_port="${WG_LISTEN_PORT:-}"
    if [[ -z "${wg_port}" && -f /etc/wireguard/wg0.conf ]]; then
        wg_port=$(grep -E '^ListenPort\s*=\s*' /etc/wireguard/wg0.conf 2>/dev/null | head -n1 | awk -F= '{gsub(/ /, "", $2); print $2}' || true)
    fi
    if [[ -n "${wg_port}" ]]; then
        allowed_udp+=("${wg_port}")
    fi

    if [[ ${lockdown_active} -eq 0 ]]; then
        # Before lockdown, SSH may still be intentionally reachable.
        allowed_tcp+=("${SSH_PORT}")
    fi

    # UFW should be active unless explicitly disabled.
    if [[ ${ENABLE_FIREWALL} -eq 1 ]]; then
        utils::require_cmd ufw "UFW is enabled in config but 'ufw' is not installed." || exit 1
        local ufw_state
        ufw_state=$(ufw status 2>/dev/null | head -n1 || true)
        if ! [[ "${ufw_state}" =~ Status:[[:space:]]+active ]]; then
            utils::log_error "UFW is not active. Expected firewall enabled for production."
            exit 1
        fi
        local ufw_verbose
        ufw_verbose=$(ufw status verbose 2>/dev/null || true)
        if ! echo "${ufw_verbose}" | grep -qiE '^Default:.*deny \(incoming\)'; then
            utils::log_warn "UFW default incoming policy is not 'deny'. Review: ufw status verbose"
        fi
    else
        utils::log_warn "Firewall is disabled via flags; skipping UFW verification."
    fi

    local -a tcp_listeners=() udp_listeners=()
    net_detect::collect_listeners tcp tcp_listeners
    net_detect::collect_listeners udp udp_listeners

    if [[ ${#tcp_listeners[@]} -eq 0 && ${#udp_listeners[@]} -eq 0 ]]; then
        utils::log_warn "No listeners discovered via 'ss'. Skipping exposure checks."
        return
    fi

    local fail=0
    local -a findings=()

    local addr ip port
    for addr in "${tcp_listeners[@]}"; do
          local ip port out
  out="$(net_detect::extract_ip_port "${addr}" || true)"
  if [[ -z "${out}" ]]; then
    log::warn "Could not parse listener address '${addr}'; skipping"
    continue
  fi
  read -r ip port <<<"${out}" || { log::warn "Could not parse listener address '${addr}'; skipping"; continue; }
        if [[ -z "${port}" ]]; then
            continue
        fi

        # VPN-only binds should not be treated as public exposure.
        if [[ -n "${wg_ip4}" && "${ip}" == "${wg_ip4}" ]]; then
            continue
        fi
        # Determine whether this listener is public-facing.
        local is_public=0
        if [[ "${ip}" == "0.0.0.0" || "${ip}" == "*" ]]; then
            is_public=1
        elif net_detect::ip_list_contains "${ip}" "${global_v4[@]}"; then
            is_public=1
        elif [[ "${ip}" == "::" || "${ip}" == "[::]" ]]; then
            is_public=1
        elif net_detect::ip_list_contains "${ip}" "${global_v6[@]}"; then
            is_public=1
        fi

        if [[ ${is_public} -eq 0 ]]; then
            continue
        fi

        if ! net_detect::ip_list_contains "${port}" "${allowed_tcp[@]}"; then
            findings+=("tcp ${ip}:${port} (unexpected)")
            fail=1
        fi
    done

    for addr in "${udp_listeners[@]}"; do
		local out=""
		out="$(net_detect::extract_ip_port "${addr}" 2>/dev/null || true)"
		if [[ -z "${out}" ]]; then
			utils::log_warn "Could not parse listener address '${addr}'; skipping"
			continue
		fi
		read -r ip port <<<"${out}"
		if [[ -z "${port:-}" ]]; then
			continue
		fi

        # VPN-only binds should not be treated as public exposure.
        if [[ -n "${wg_ip4}" && "${ip}" == "${wg_ip4}" ]]; then
            continue
        fi
        local is_public=0
        if [[ "${ip}" == "0.0.0.0" || "${ip}" == "*" ]]; then
            is_public=1
        elif net_detect::ip_list_contains "${ip}" "${global_v4[@]}"; then
            is_public=1
        elif [[ "${ip}" == "::" || "${ip}" == "[::]" ]]; then
            is_public=1
        elif net_detect::ip_list_contains "${ip}" "${global_v6[@]}"; then
            is_public=1
        fi
        if [[ ${is_public} -eq 0 ]]; then
            continue
        fi

        if ! net_detect::ip_list_contains "${port}" "${allowed_udp[@]}"; then
            findings+=("udp ${ip}:${port} (unexpected)")
            fail=1
        fi
    done

    # Targeted checks for common foot-guns
    if ss -H -lnt 2>/dev/null | grep -qE "(0.0.0.0|\[::\]):${NPM_ADMIN_BACKEND_PORT:-8181}\b"; then
        findings+=("tcp 0.0.0.0:${NPM_ADMIN_BACKEND_PORT:-8181} (NPM admin exposed)")
        fail=1
    fi
    if ss -H -lnt 2>/dev/null | grep -qE "(0.0.0.0|\[::\]):3001\b"; then
        findings+=("tcp 0.0.0.0:3001 (Uptime Kuma exposed)")
        fail=1
    fi

    if [[ ${fail} -eq 1 ]]; then
        utils::log_error "Unexpected public listeners detected. Expected public TCP: ${allowed_tcp[*]} ; public UDP: ${allowed_udp[*]:-none}"
        local item
        for item in "${findings[@]}"; do
            utils::log_error "  - ${item}"
        done
        utils::log_error "Fix: stop/disable the offending service or bind it to wg0/localhost, then re-run: sudo ${INSTALL_BIN} verify"
        exit 1
    fi

    # Best-effort readiness diagnostics: confirms that the proxied backends are listening on localhost.
    # This does not fail verification because backend availability can legitimately lag during boot.
    net_detect::diagnose_socket_proxy_backends tcp_listeners

    utils::log_info "Security posture check passed: no unexpected public listeners detected."
}

verify::nf_tables_after_reboot() {
  # Purpose: Nf tables after reboot.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${RESUME_MODE} -eq 0 ]]; then
        return
    fi
    steps::status_cmd bash -c "lsmod | grep -E 'nf_tables|nfnetlink' || true"
}
