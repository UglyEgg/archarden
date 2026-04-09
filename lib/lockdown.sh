# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Lockdown (stage 2) logic: wg-only SSH policy apply/status/revert.
# Extracted from archarden to keep CLI dispatch code smaller.

lockdown::status_report() {
  # Purpose: Status report.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "Lockdown status"

    local wg0_present="no"
    if ip link show wg0 >/dev/null 2>&1; then
        wg0_present="yes"
    fi

    local wg_service_state="unknown"
    if utils::have_cmd systemctl; then
        if systemctl is-active --quiet wg-quick@wg0.service 2>/dev/null; then
            wg_service_state="active"
        else
            wg_service_state="inactive"
        fi
    fi

    local marker_state="absent"
    local marker_value=""
    if [[ -f "${LOCKDOWN_MARKER_FILE}" ]]; then
        marker_state="present"
        marker_value="$(cat "${LOCKDOWN_MARKER_FILE}" 2>/dev/null || true)"
    fi

    local ufw_state="missing"
    local ufw_out=""
    if utils::have_cmd ufw; then
        ufw_out="$(ufw status 2>/dev/null || true)"
        local first_line
        first_line="$(echo "${ufw_out}" | head -n 1)"
        if [[ "${first_line}" == Status:* ]]; then
            ufw_state="${first_line#Status: }"
        else
            ufw_state="unknown"
        fi
    fi

    local sshd_active="unknown"
    local sshd_enabled="unknown"
    if utils::have_cmd systemctl; then
        if systemctl is-active --quiet sshd.service 2>/dev/null; then
            sshd_active="active"
        else
            sshd_active="inactive"
        fi
        if systemctl is-enabled --quiet sshd.service 2>/dev/null; then
            sshd_enabled="enabled"
        else
            sshd_enabled="disabled"
        fi
    else
        if ss -tln 2>/dev/null | grep -q ":${SSH_PORT} "; then
            sshd_active="listening"
        else
            sshd_active="not-listening"
        fi
    fi

    local ssh_firewall_mode="unknown"
    if [[ "${ufw_state}" == "active" ]]; then
        local wg_rule=0
        local public_rule=0
        while IFS= read -r line; do
            [[ -n "${line}" ]] || continue
            if [[ "${line}" == *"${SSH_PORT}/tcp"* ]]; then
                if [[ "${line}" == *"on wg0"* ]]; then
                    wg_rule=1
                else
                    public_rule=1
                fi
            fi
        done < <(echo "${ufw_out}" | tail -n +3)

        if [[ ${wg_rule} -eq 1 && ${public_rule} -eq 0 ]]; then
            ssh_firewall_mode="wg-only"
        elif [[ ${public_rule} -eq 1 && ${wg_rule} -eq 0 ]]; then
            ssh_firewall_mode="public"
        elif [[ ${public_rule} -eq 1 && ${wg_rule} -eq 1 ]]; then
            ssh_firewall_mode="public+wg"
        else
            ssh_firewall_mode="blocked"
        fi
    elif [[ "${ufw_state}" == "inactive" ]]; then
        ssh_firewall_mode="ufw-inactive"
    fi

    echo
    echo "  wg0: ${wg0_present} (wg-quick@wg0: ${wg_service_state})"
    if [[ "${marker_state}" == "present" && -n "${marker_value}" ]]; then
        echo "  lockdown marker: ${marker_state} (${marker_value})"
    else
        echo "  lockdown marker: ${marker_state}"
    fi
    echo "  sshd: ${sshd_active} (enabled: ${sshd_enabled})"
    local ssh_bind_mode="unknown"
    local wg_bind_dropin_state="absent"
    if [[ -f "${SSHD_WG_ONLY_DROPIN}" ]]; then
        wg_bind_dropin_state="present"
    fi
    if ss -H -lnt 2>/dev/null | grep -q ":${SSH_PORT}\b"; then
        local wg_ip
        wg_ip=$(ip -o -4 addr show dev wg0 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -n1 || true)
        if [[ -n "${wg_ip}" ]] && ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qx "${wg_ip}:${SSH_PORT}"; then
            ssh_bind_mode="wg-only"
        elif ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE "(0.0.0.0|\[::\]|::):${SSH_PORT}\b"; then
            ssh_bind_mode="wildcard"
        else
            ssh_bind_mode="other"
        fi
    else
        ssh_bind_mode="not-listening"
    fi
    echo "  sshd bind: ${ssh_bind_mode} (wg-only drop-in: ${wg_bind_dropin_state})"
    echo "  ufw: ${ufw_state}"
    echo "  ssh firewall: ${ssh_firewall_mode} (port ${SSH_PORT})"
    echo
    echo "  To enforce wg-only SSH after verifying WireGuard: sudo ${INSTALL_BIN} lockdown"
    echo "  To revert lockdown (restore standard SSH policy): sudo ${INSTALL_BIN} lockdown --revert"
    echo "  Recovery: use your VPS console to adjust firewall/sshd if you lock yourself out."
}

lockdown::run() {
  # Purpose: Run the requested state. (systemd)
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Stage-2 action: restrict SSH ingress to WireGuard (wg0) only.

  # Respect any LOG_FILE provided by the caller.
  # Default to phase1 utils::log only when using the default phase0 utils::log.
    if [[ "$(id -u)" -eq 0 && "${LOG_FILE}" == "${PHASE0_LOG}" ]]; then
        LOG_FILE="${PHASE1_LOG}"
    fi
    export LOG_FILE

    utils::require_root

    if [[ ${LOCKDOWN_STATUS} -eq 1 && ${LOCKDOWN_REVERT} -eq 1 ]]; then
        utils::log_error "--status and --revert are mutually exclusive"
        exit 1
    fi

    if [[ ${LOCKDOWN_STATUS} -eq 1 ]]; then
        lockdown::status_report
        return 0
    fi

    if [[ ${LOCKDOWN_REVERT} -eq 1 ]]; then
        # Recovery action: revert lockdown profile and restore the standard UFW SSH policy.

        RUN_ID="unlockdown-$(date -u '+%Y%m%d%H%M%S')"
        backup::init_run_dir

        utils::log_info "Lockdown revert: restoring standard firewall profile (stage 1)."
        utils::log_info "This will reset and re-apply UFW rules owned by archarden."

        firewall::configure_ufw_revert
        ssh::revert_sshd_wg_only_listener

        if [[ ${DRY_RUN} -eq 0 ]]; then
            if [[ -f "${LOCKDOWN_MARKER_FILE}" ]]; then
                utils::run_cmd "rm -f \"${LOCKDOWN_MARKER_FILE}\""
            fi
        else
            utils::log_info "[DRY-RUN] Would remove lockdown marker at ${LOCKDOWN_MARKER_FILE}"
        fi

        utils::log_info "Revert complete. SSH is no longer restricted to wg0 only."
        return 0
    fi


    # Establish a minimal backup context so lockdown changes can be captured
    # without depending on the phase0 initializer.
    RUN_ID="lockdown-$(date -u '+%Y%m%d%H%M%S')"
    backup::init_run_dir

    utils::log_info "Lockdown: restricting SSH to wg0 only (stage 2)."
    utils::log_info "This will reset and re-apply UFW rules owned by archarden."

    if [[ ${DRY_RUN} -eq 0 ]]; then
        if utils::have_cmd systemctl; then
            if ! systemctl is-active --quiet wg-quick@wg0.service; then
                utils::log_error "wg-quick@wg0.service is not active. Connect WireGuard first, then re-run: archarden lockdown"
                exit 1
            fi
        fi
        if ! ip link show wg0 >/dev/null 2>&1; then
            utils::log_error "WireGuard interface wg0 not found. Ensure WireGuard is configured and running before lockdown."
            exit 1
        fi
    else
        utils::log_info "[DRY-RUN] Would verify WireGuard interface wg0 is up"
    fi

    firewall::configure_ufw_lockdown

    # Bind sshd to the WireGuard interface to reduce exposure beyond firewall policy.
    ssh::configure_sshd_wg_only_listener

    if [[ ${DRY_RUN} -eq 0 ]]; then
        fs::ensure_dir "${STATE_DIR}" 0700 root root
        utils::run_cmd "date -u '+%Y-%m-%dT%H:%M:%SZ' > \"${LOCKDOWN_MARKER_FILE}\""
        utils::run_cmd "chmod 0600 \"${LOCKDOWN_MARKER_FILE}\""

        if ss -tulpn 2>/dev/null | grep -q ":${SSH_PORT}"; then
            utils::log_info "SSH appears to be listening on port ${SSH_PORT}"
        else
            utils::log_warn "No listener detected on port ${SSH_PORT}. Firewall is locked down, but sshd may not be reachable."
        fi
    else
        utils::log_info "[DRY-RUN] Would write lockdown marker to ${LOCKDOWN_MARKER_FILE}"
    fi

    utils::log_info "Lockdown complete. SSH is now permitted only via wg0." 
}
