# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

firewall::configure_ufw() {
  # Purpose: Configure ufw. (firewall)
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${ENABLE_FIREWALL} -eq 0 ]]; then
        utils::log_warn "Firewall configuration disabled by flag"
        return
    fi
    wireguard::ensure_config_loaded
    firewall::_ensure_backend
    utils::require_cmd ufw "ufw command not found; install the ufw package." || exit 1

    backup::file /etc/default/ufw
    utils::run_cmd "sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw"
    utils::run_cmd "ufw --force reset"
    utils::run_cmd "ufw default deny incoming"
    utils::run_cmd "ufw default allow outgoing"

    if firewall::_iptables_is_nft; then
        utils::log_info "iptables backend reports nf_tables (nft)"
    else
        utils::log_warn "UFW backend is not reporting nftables; ensure the current Arch `iptables` package is installed (nft-backed) and that legacy tooling is not forcing a non-nft path."
    fi

    if [[ -n "${RESTRICT_SSH_CIDR}" ]]; then
        utils::run_cmd "ufw allow from ${RESTRICT_SSH_CIDR} to any port ${SSH_PORT} proto tcp"
    else
        utils::run_cmd "ufw limit ${SSH_PORT}/tcp"
    fi

    if [[ ${KEEP_SSH_22} -eq 1 ]]; then
        utils::run_cmd "ufw allow 22/tcp"
    fi

    local allowlist_entries=()
    while IFS= read -r port; do
        allowlist_entries+=("${port}")
    done < <(steps::read_packages_from_file "${CONFIG_DIR}/firewall_allow.list" 1)

    if [[ ${#allowlist_entries[@]} -eq 0 ]]; then
        utils::log_warn "No firewall allowlist entries defined; skipping port allows"
    else
        for port in "${allowlist_entries[@]}"; do
            utils::run_cmd "ufw allow ${port}"
        done
    fi

    utils::run_cmd "ufw allow ${WG_LISTEN_PORT}/udp comment 'WireGuard'"
    utils::run_cmd "ufw allow in on wg0 to any port 53 proto udp comment 'DNS (VPN)'"
    utils::run_cmd "ufw allow in on wg0 to any port 53 proto tcp comment 'DNS (VPN)'"
    utils::run_cmd "ufw allow in on wg0 to any port ${NPM_ADMIN_PORT:-81} proto tcp comment 'NPM Admin (VPN)'"
    utils::run_cmd "ufw allow in on wg0 to any port 3001 proto tcp comment 'Uptime Kuma (VPN)'"

    if [[ ${SKIP_FIREWALL_ENABLE} -eq 1 ]]; then
        utils::log_warn "Skipping firewall enable as requested"
        return
    fi

	utils::run_cmd "ufw --force enable"
    systemd::enable ufw
	utils::run_cmd "ufw reload"

	# UFW can reset rule file permissions on reload; enforce non-world-readable modes
	# after the final reload to avoid noisy WARN lines.
	utils::ensure_file_permissions /etc/ufw/user.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/before.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/after.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/user6.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/before6.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/after6.rules 0640 root || true
}

firewall::configure_ufw_lockdown() {
  # Purpose: Configure ufw lockdown. (firewall)
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Stage-2 firewall profile: keep public ingress limited to the allowlist
  # (typically 80/443) and restrict SSH to wg0 only.
    if [[ ${ENABLE_FIREWALL} -eq 0 ]]; then
        utils::log_error "Firewall is disabled (--disable-firewall); cannot apply lockdown"
        exit 1
    fi

    # WireGuard settings are used for the WG listen port; the peer list is not required.
    wireguard::ensure_config_loaded

    if [[ ${DRY_RUN} -eq 0 ]]; then
        firewall::_ensure_backend
        utils::require_cmd ufw "ufw command not found; install the ufw package." || exit 1
    else
        utils::log_info "[DRY-RUN] Would ensure firewall backend and ufw availability"
    fi

    if [[ -n "${RESTRICT_SSH_CIDR}" ]]; then
        utils::log_warn "Lockdown enforces wg0-only SSH; ignoring --restrict-ssh-cidr=${RESTRICT_SSH_CIDR}"
    fi
    if [[ ${KEEP_SSH_22} -eq 1 ]]; then
        utils::log_warn "Lockdown enforces wg0-only SSH; ignoring --keep-ssh-22"
    fi

    backup::file /etc/default/ufw
    utils::run_cmd "sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw"
    utils::run_cmd "ufw --force reset"
    utils::run_cmd "ufw default deny incoming"
    utils::run_cmd "ufw default allow outgoing"

    local allowlist_entries=()
    while IFS= read -r port; do
        allowlist_entries+=("${port}")
    done < <(steps::read_packages_from_file "${CONFIG_DIR}/firewall_allow.list" 1)

    if [[ ${#allowlist_entries[@]} -eq 0 ]]; then
        utils::log_warn "No firewall allowlist entries defined; skipping public port allows"
    else
        local port
        for port in "${allowlist_entries[@]}"; do
            utils::run_cmd "ufw allow ${port}"
        done
    fi

    if [[ -z "${WG_LISTEN_PORT}" ]]; then
        utils::log_error "WireGuard listen port not set; cannot apply lockdown firewall profile"
        exit 1
    fi
    utils::run_cmd "ufw allow ${WG_LISTEN_PORT}/udp comment 'WireGuard'"

    # Internal DNS for VPN clients (dnsmasq bound to wg0).
    utils::run_cmd "ufw allow in on wg0 to any port 53 proto udp comment 'DNS (VPN)'"
    utils::run_cmd "ufw allow in on wg0 to any port 53 proto tcp comment 'DNS (VPN)'"

    # SSH is VPN-only in lockdown.
    utils::run_cmd "ufw allow in on wg0 to any port ${SSH_PORT} proto tcp comment 'SSH (VPN only)'"

    # Preserve current admin-plane intent (to be normalized in later workloads).
    utils::run_cmd "ufw allow in on wg0 to any port ${NPM_ADMIN_PORT:-81} proto tcp comment 'NPM Admin (VPN)'"
    utils::run_cmd "ufw allow in on wg0 to any port 3001 proto tcp comment 'Uptime Kuma (VPN)'"

    if [[ ${SKIP_FIREWALL_ENABLE} -eq 1 ]]; then
        utils::log_warn "Skipping firewall enable as requested"
        return
    fi

    utils::run_cmd "ufw --force enable"
    systemd::enable ufw
    utils::run_cmd "ufw reload"

    # ufw can emit warnings if its rules files are world-readable. This is not
    # normally fatal, but it clutters logs and can mask real issues.
    utils::ensure_file_permissions /etc/ufw/user.rules 0640 root || true
    utils::ensure_file_permissions /etc/ufw/before.rules 0640 root || true
    utils::ensure_file_permissions /etc/ufw/after.rules 0640 root || true
    utils::ensure_file_permissions /etc/ufw/user6.rules 0640 root || true
    utils::ensure_file_permissions /etc/ufw/before6.rules 0640 root || true
    utils::ensure_file_permissions /etc/ufw/after6.rules 0640 root || true
}

firewall::configure_ufw_revert() {
  # Purpose: Configure ufw revert. (firewall)
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Recovery profile used by `archarden lockdown --revert`.
  # Restores the standard firewall SSH policy (public limit/restrict) while
  # keeping the public allowlist ports and (when detectable) WireGuard UDP.
    if [[ ${ENABLE_FIREWALL} -eq 0 ]]; then
        utils::log_error "Firewall is disabled (--disable-firewall); cannot revert lockdown"
        exit 1
    fi

    if [[ ${DRY_RUN} -eq 0 ]]; then
        firewall::_ensure_backend
        utils::require_cmd ufw "ufw command not found; install the ufw package." || exit 1
    else
        utils::log_info "[DRY-RUN] Would ensure firewall backend and ufw availability"
    fi

    backup::file /etc/default/ufw
    utils::run_cmd "sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw"
    utils::run_cmd "ufw --force reset"
    utils::run_cmd "ufw default deny incoming"
    utils::run_cmd "ufw default allow outgoing"

    if [[ -n "${RESTRICT_SSH_CIDR}" ]]; then
        utils::run_cmd "ufw allow from ${RESTRICT_SSH_CIDR} to any port ${SSH_PORT} proto tcp"
    else
        utils::run_cmd "ufw limit ${SSH_PORT}/tcp"
    fi

    if [[ ${KEEP_SSH_22} -eq 1 ]]; then
        utils::run_cmd "ufw allow 22/tcp"
    fi

    local allowlist_entries=()
    while IFS= read -r port; do
        allowlist_entries+=("${port}")
    done < <(steps::read_packages_from_file "${CONFIG_DIR}/firewall_allow.list" 1)

    if [[ ${#allowlist_entries[@]} -eq 0 ]]; then
        utils::log_warn "No firewall allowlist entries defined; skipping public port allows"
    else
        local port
        for port in "${allowlist_entries[@]}"; do
            utils::run_cmd "ufw allow ${port}"
        done
    fi

    # Best-effort WireGuard UDP allow. Do not fail if it cannot be discovered.
    local wg_port="${WG_LISTEN_PORT}"
    if [[ -z "${wg_port}" && -f /etc/wireguard/wg0.conf ]]; then
        wg_port=$(grep -E '^ListenPort\s*=\s*' /etc/wireguard/wg0.conf 2>/dev/null | head -n 1 | awk -F= '{gsub(/ /, "", $2); print $2}' || true)
    fi
    if [[ -n "${wg_port}" ]]; then
        utils::run_cmd "ufw allow ${wg_port}/udp comment 'WireGuard'"
    else
        utils::log_warn "WireGuard listen port not known; skipping WireGuard UDP allow"
    fi

    # Internal DNS for VPN clients (dnsmasq bound to wg0).
    utils::run_cmd "ufw allow in on wg0 to any port 53 proto udp comment 'DNS (VPN)'"
    utils::run_cmd "ufw allow in on wg0 to any port 53 proto tcp comment 'DNS (VPN)'"

    if [[ ${SKIP_FIREWALL_ENABLE} -eq 1 ]]; then
        utils::log_warn "Skipping firewall enable as requested"
        return
    fi

    utils::run_cmd "ufw --force enable"
    systemd::enable ufw
    utils::run_cmd "ufw reload"

	# UFW emits warnings if rule files are world-readable. Some operations (including reload)
	# can reset permissions, so enforce after the final reload.
	utils::ensure_file_permissions /etc/ufw/user.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/before.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/after.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/user6.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/before6.rules 0640 root || true
	utils::ensure_file_permissions /etc/ufw/after6.rules 0640 root || true
}

firewall::_ensure_backend() {
  # Purpose: Ensure backend.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if ! utils::have_cmd nft; then
        utils::log_error "nft command not found; firewall configuration cannot continue."
        exit 1
    fi

    if nft list tables >/dev/null 2>&1; then
        return
    fi

    utils::log_warn "nftables backend unavailable; attempting to load firewall kernel modules"
    local modules=()
    while IFS= read -r mod; do
        modules+=("${mod}")
    done < <(steps::read_packages_from_file "${CONFIG_DIR}/firewall_modules.list")
    for mod in "${modules[@]}"; do
        if modinfo "${mod}" >/dev/null 2>&1; then
            utils::run_cmd "modprobe ${mod} || true"
        fi
    done

    if nft list tables >/dev/null 2>&1; then
        utils::log_info "Firewall kernel modules loaded successfully"
        return
    fi

    utils::log_error "nftables backend still unavailable. Ensure firewall kernel modules are present or rerun with --skip-firewall-enable or --disable-firewall."
    exit 1
}

firewall::_iptables_is_nft() {
  # Purpose: Detect whether the active iptables backend is nftables (nf_tables).
  # Outputs: Return 0 if nft, 1 otherwise.
    local ipt
    if ! utils::have_cmd iptables; then
        return 1
    fi

    # On current Arch, the `iptables` package is nft-backed. The most reliable
    # runtime signal is that the version string includes "nf_tables".
    if iptables --version 2>/dev/null | grep -q "nf_tables"; then
        return 0
    fi

    # Fallback: resolve the iptables binary path.
    ipt="$(command -v iptables 2>/dev/null || true)"
    if [[ -n "${ipt}" ]] && readlink -f "${ipt}" 2>/dev/null | grep -q "nft"; then
        return 0
    fi

    return 1
}
