# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

configure_ufw() {
    if [[ ${ENABLE_FIREWALL} -eq 0 ]]; then
        log_warn "Firewall configuration disabled by flag"
        return
    fi
    ensure_wireguard_config_loaded
    ensure_firewall_backend

    if ! command -v ufw >/dev/null 2>&1; then
        log_error "ufw command not found; install the ufw package."
        exit 1
    fi

    backup_file /etc/default/ufw
    run_cmd "sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw || echo 'IPV6=yes' >> /etc/default/ufw"
    run_cmd "ufw --force reset"
    run_cmd "ufw default deny incoming"
    run_cmd "ufw default allow outgoing"

    if ufw --version 2>/dev/null | grep -qi nftables; then
        log_info "UFW reports nftables backend"
    else
        log_warn "UFW backend is not reporting nftables; ensure iptables-nft is the active alternative."
    fi

    if [[ -n "${RESTRICT_SSH_CIDR}" ]]; then
        run_cmd "ufw allow from ${RESTRICT_SSH_CIDR} to any port ${SSH_PORT} proto tcp"
    else
        run_cmd "ufw limit ${SSH_PORT}/tcp"
    fi

    if ss -tulpn 2>/dev/null | grep -q ':22'; then
        run_cmd "ufw allow 22/tcp"
    fi
    if [[ ${KEEP_SSH_22} -eq 1 ]]; then
        run_cmd "ufw allow 22/tcp"
    fi

    local allowlist_entries=()
    while IFS= read -r port; do
        allowlist_entries+=("${port}")
    done < <(read_packages_from_file "${CONFIG_DIR}/firewall_allow.list" 1)

    if [[ ${#allowlist_entries[@]} -eq 0 ]]; then
        log_warn "No firewall allowlist entries defined; skipping port allows"
    else
        for port in "${allowlist_entries[@]}"; do
            run_cmd "ufw allow ${port}"
        done
    fi

    run_cmd "ufw allow ${WG_LISTEN_PORT}/udp comment 'WireGuard'"
    run_cmd "ufw allow in on wg0 to any port 81 proto tcp comment 'NPM Admin (VPN)'"
    run_cmd "ufw allow in on wg0 to any port 3001 proto tcp comment 'Uptime Kuma (VPN)'"

    if [[ ${SKIP_FIREWALL_ENABLE} -eq 1 ]]; then
        log_warn "Skipping firewall enable as requested"
        return
    fi

    run_cmd "ufw --force enable"
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd "systemctl enable --now ufw"
    else
        log_warn "systemctl not found; ensure ufw starts on boot"
    fi
    if [[ ${KEEP_SSH_22} -eq 0 ]]; then
        if [ "${DRY_RUN}" -eq 0 ]; then
            ufw delete allow 22/tcp >/dev/null 2>&1 || true
        else
            log_info "[DRY-RUN] Would remove legacy SSH port 22 rule"
        fi
    fi
    run_cmd "ufw reload"
}

ensure_firewall_backend() {
    if ! command -v nft >/dev/null 2>&1; then
        log_error "nft command not found; firewall configuration cannot continue."
        exit 1
    fi

    if nft list tables >/dev/null 2>&1; then
        return
    fi

    log_warn "nftables backend unavailable; attempting to load firewall kernel modules"
    local modules=()
    while IFS= read -r mod; do
        modules+=("${mod}")
    done < <(read_packages_from_file "${CONFIG_DIR}/firewall_modules.list")
    for mod in "${modules[@]}"; do
        if modinfo "${mod}" >/dev/null 2>&1; then
            run_cmd "modprobe ${mod} || true"
        fi
    done

    if nft list tables >/dev/null 2>&1; then
        log_info "Firewall kernel modules loaded successfully"
        return
    fi

    log_error "nftables backend still unavailable. Ensure firewall kernel modules are present or rerun with --skip-firewall-enable or --disable-firewall."
    exit 1
}
