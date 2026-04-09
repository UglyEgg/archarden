# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

ssh::configure_sshd() {
  # Purpose: Configure sshd.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local hardening_tmp
    mkdir -p "${SSHD_CONFIG_DIR}"
    utils::run_cmd "ssh-keygen -A"
    backup::file "${SSHD_HARDENING_DROPIN}"
    backup::file "${SSHD_CRYPTO_DROPIN}"
    backup::file "${SSHD_PORT_FORWARDING_DROPIN}"
    hardening_tmp=$(mktemp)
    sed "s/__SSH_PORT__/${SSH_PORT}/g" "${CONFIG_DIR}/sshd_hardening.conf" > "${hardening_tmp}"
    if [[ ${KEEP_SSH_22} -eq 1 && "${SSH_PORT}" != "22" ]]; then
        printf '\nPort 22\n' >> "${hardening_tmp}"
        utils::log_warn "Keeping SSH on legacy port 22 alongside ${SSH_PORT} (requested by --keep-ssh-22)."
    fi
    utils::write_file_atomic "${SSHD_HARDENING_DROPIN}" < "${hardening_tmp}"
    rm -f "${hardening_tmp}"
    utils::write_file_atomic "${SSHD_CRYPTO_DROPIN}" < "${CONFIG_DIR}/sshd_crypto_hardening.conf"
    ssh::_configure_port_forwarding_dropin
    if [ "${DRY_RUN}" -eq 0 ]; then
        if ! sshd -t; then
            utils::log_error "sshd configuration failed validation"
            ssh::_restore_sshd_dropins
            exit 1
        fi
        ssh::_log_effective_port_forwarding
    else
        utils::log_info "[DRY-RUN] Skipping sshd validation"
    fi
}

ssh::_configure_port_forwarding_dropin() {
  # Purpose: Configure port forwarding dropin.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -z "${USER_NAME}" ]]; then
        utils::log_error "SSH admin user is not set; cannot configure port forwarding drop-in."
        exit 1
    fi
    local wg_ip
    wg_ip="${WG_INTERFACE_ADDRESS%%/*}"
    if [[ -z "${wg_ip}" || "${wg_ip}" == "${WG_INTERFACE_ADDRESS}" ]]; then
        wg_ip="10.66.66.1"
    fi
    utils::render_template "${CONFIG_DIR}/sshd_port_forwarding.conf" "${SSHD_PORT_FORWARDING_DROPIN}" \
        "SSH_ADMIN_USER=${USER_NAME}" \
        "WG_BIND_IP=${wg_ip}" \
        "NPM_ADMIN_PORT=${NPM_ADMIN_PORT:-81}"         "NPM_ADMIN_BACKEND_PORT=${NPM_ADMIN_BACKEND_PORT:-8181}"
    utils::ensure_file_permissions "${SSHD_PORT_FORWARDING_DROPIN}" 0644 root root
    utils::log_info "Configured sshd port forwarding policy for ${USER_NAME}"
}

ssh::_log_effective_port_forwarding() {
  # Purpose: Log effective port forwarding.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would utils::log effective sshd port forwarding configuration"
        return
    fi
    steps::status_cmd "sshd -T | grep -i 'allowtcpforwarding' || true"
}

ssh::_ensure_admin_sudoers() {
  # Purpose: Ensure admin sudoers.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local sudoers_file=/etc/sudoers.d/90-archarden-ssh-user tmp
    tmp=$(mktemp)
    printf "%s ALL=(ALL) NOPASSWD: ALL\n" "${USER_NAME}" > "${tmp}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would install sudoers entry at ${sudoers_file} for ${USER_NAME}"
        rm -f "${tmp}"
        return
    fi
    backup::file "${sudoers_file}"
    install -D -m 0440 "${tmp}" "${sudoers_file}"
    chown root:root "${sudoers_file}"
    rm -f "${tmp}"
}

ssh::create_admin_user() {
  # Purpose: Create admin user.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -z "${USER_NAME}" ]]; then
        return
    fi
    if id -u "${USER_NAME}" >/dev/null 2>&1; then
        utils::log_info "User ${USER_NAME} already exists"
    else
        utils::run_cmd "useradd -m -G wheel,ssh -s /bin/bash ${USER_NAME}"
        utils::log_info "Created user ${USER_NAME} and added to wheel,ssh"
    fi
    ssh::ensure_user_in_group "${USER_NAME}" wheel
    ssh::ensure_user_in_group "${USER_NAME}" ssh
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would lock password for ${USER_NAME}"
    else
        utils::run_cmd "passwd -l ${USER_NAME}"
    fi
    USER_HOME=$(getent passwd "${USER_NAME}" | cut -d: -f6)
    if [[ -z "${USER_HOME}" ]]; then
        utils::log_error "Unable to determine home for ${USER_NAME}"
        exit 1
    fi
    if [[ -n "${PUBKEY_FILE}" ]]; then
        PUBKEY_VALUE=$(cat "${PUBKEY_FILE}")
    fi
    if [[ -n "${PUBKEY_VALUE}" ]]; then
        local ssh_dir="${USER_HOME}/.ssh"
        fs::ensure_dir "${ssh_dir}" 700 "${USER_NAME}" "${USER_NAME}"
        local auth_keys="${ssh_dir}/authorized_keys"
        if [ "${DRY_RUN}" -eq 0 ]; then
            if [ ! -f "${auth_keys}" ]; then
                touch "${auth_keys}"
                chown "${USER_NAME}:${USER_NAME}" "${auth_keys}"
                chmod 600 "${auth_keys}"
            fi
            if ! grep -qxF "${PUBKEY_VALUE}" "${auth_keys}"; then
                echo "${PUBKEY_VALUE}" >>"${auth_keys}"
            fi
        else
            utils::log_info "[DRY-RUN] Would add key for ${USER_NAME}"
        fi
    else
        utils::log_warn "No public key provided for ${USER_NAME}; ensure key-based auth manually."
    fi

    ssh::_ensure_admin_sudoers
}

ssh::ensure_ssh_group() {
  # Purpose: Ensure ssh group.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if getent group ssh >/dev/null 2>&1; then
        local current_gid
        current_gid=$(getent group ssh | cut -d: -f3)
        if (( current_gid < 1000 )); then
            utils::log_info "SSH access group 'ssh' already exists as a system group (gid ${current_gid})"
            return
        fi

        local new_gid
        if ! new_gid=$(steps::next_available_system_gid); then
            utils::log_error "Unable to find a free system gid (<1000) to convert 'ssh' group"
            exit 1
        fi

        utils::run_cmd "groupmod -g ${new_gid} ssh"
        utils::log_warn "Converted existing 'ssh' group to system gid ${new_gid}"
        return
    fi

    utils::run_cmd "groupadd -r ssh"
    utils::log_info "Created system group 'ssh' for SSH access control"
}

ssh::ensure_user_in_group() {
  # Purpose: Ensure user in group.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local user="$1" group="$2"
    if ! id -u "${user}" >/dev/null 2>&1; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            utils::log_info "[DRY-RUN] Would ensure ${user} is in group ${group}"
            return
        fi
        utils::log_error "User ${user} does not exist; cannot add to ${group}"
        exit 1
    fi
    if id -nG "${user}" | tr ' ' '\n' | grep -qx "${group}"; then
        return
    fi
    utils::run_cmd "usermod -aG ${group} ${user}"
    utils::log_info "Added ${user} to ${group}"
}

ssh::_restore_sshd_dropins() {
  # Purpose: Restore sshd dropins.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local restored=0 dropin latest_backup backup_pattern
    for dropin in "${SSHD_HARDENING_DROPIN}" "${SSHD_CRYPTO_DROPIN}" "${SSHD_PORT_FORWARDING_DROPIN}"; do
        latest_backup=""
        if [[ -n "${BACKUP_ROOT:-}" ]]; then
            backup_pattern="${BACKUP_ROOT}/configs/${dropin#/}"
			latest_backup=$(find "$(dirname "${backup_pattern}")" -maxdepth 1 -type f -name "$(basename "${backup_pattern}").*.bak" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)
        fi
        if [[ -z "${latest_backup}" ]]; then
			latest_backup=$(find "$(dirname "${dropin}")" -maxdepth 1 -type f -name "$(basename "${dropin}").*.bak" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)
        fi
        if [[ -n "${latest_backup}" ]]; then
            utils::run_cmd "cp -p \"${latest_backup}\" \"${dropin}\""
            restored=1
		elif [[ -f "${dropin}" ]]; then
			utils::run_cmd "rm -f \"${dropin}\""
            restored=1
            utils::log_warn "Removed ${dropin} after failure; no backup was available."
        fi
    done
    if [[ ${restored} -eq 1 ]]; then
        utils::log_warn "Restored previous sshd drop-ins from backups after failure."
    fi
    return ${restored}
}

ssh::_log_effective_crypto() {
  # Purpose: Log effective crypto.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would utils::log effective sshd crypto configuration"
        return
    fi
    steps::status_cmd "sshd -T | grep -E 'kexalgorithms|ciphers|macs|hostkeyalgorithms|pubkeyacceptedalgorithms' || true"
}

ssh::__verify_sshd_port() {
  # Purpose: Verify sshd port.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if ss -tulpn | grep -q ":${SSH_PORT}"; then
        return 0
    fi
    return 1
}

ssh::restart_sshd_and_verify() {
  # Purpose: Restart sshd and verify.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [ "${DRY_RUN}" -eq 0 ]; then
        if systemd::restart sshd; then
            if ssh::__verify_sshd_port; then
                ssh::_log_effective_crypto
                return
            fi
            utils::log_error "sshd is not listening on port ${SSH_PORT} after restart"
        else
            utils::log_error "sshd restart failed"
        fi
        utils::log_warn "Attempting to restore previous sshd configuration after restart failure"
        ssh::_restore_sshd_dropins
        if sshd -t && systemd::restart sshd && ssh::__verify_sshd_port; then
            utils::log_warn "Restored previous sshd drop-ins after restart failure"
            ssh::_log_effective_crypto
            return
        fi
        utils::log_error "Unable to recover sshd service after restart failure; manual intervention required."
        exit 1
    else
        utils::log_info "[DRY-RUN] Would restart sshd and verify port ${SSH_PORT}"
    fi
}

ssh::__wg_listen_address() {
  # Purpose: Wg listen address.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local wg_ip
    wg_ip="${WG_INTERFACE_ADDRESS%%/*}"
    if [[ -z "${wg_ip}" || "${wg_ip}" == "${WG_INTERFACE_ADDRESS}" ]]; then
        wg_ip="10.66.66.1"
    fi
    echo "${wg_ip}"
}

ssh::configure_sshd_wg_only_listener() {
  # Purpose: Configure sshd wg only listener.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local wg_ip dropin
    wg_ip="$(ssh::__wg_listen_address)"
    dropin="${SSHD_WG_ONLY_DROPIN}"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure ${SSHD_CONFIG_DIR} exists"
        utils::log_info "[DRY-RUN] Would bind sshd to WireGuard only via ${dropin} (ListenAddress ${wg_ip})"
        return
    fi

    mkdir -p "${SSHD_CONFIG_DIR}"
    backup::file "${dropin}"

    cat > "${dropin}" <<EOT
# managed: archarden
AddressFamily inet
ListenAddress ${wg_ip}
EOT
    utils::ensure_file_permissions "${dropin}" 0644 root root

    if ! sshd -t; then
        utils::log_error "sshd validation failed after writing ${dropin}"
        ssh::_restore_sshd_dropins
        exit 1
    fi

    systemd::restart sshd

    if ! ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qx "${wg_ip}:${SSH_PORT}"; then
        utils::log_error "sshd is not listening on ${wg_ip}:${SSH_PORT} after wg-only bind"
        exit 1
    fi
    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE "(0.0.0.0|\[::\]|::):${SSH_PORT}\\b"; then
        utils::log_error "sshd appears to be listening on a wildcard address for port ${SSH_PORT} after wg-only bind"
        exit 1
    fi

    utils::log_info "sshd is now bound to WireGuard interface only (${wg_ip}:${SSH_PORT})"
}

ssh::revert_sshd_wg_only_listener() {
  # Purpose: Revert sshd wg only listener.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dropin
    dropin="${SSHD_WG_ONLY_DROPIN}"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would remove wg-only sshd listener drop-in ${dropin} and restart sshd"
        return
    fi

    if [[ -f "${dropin}" ]]; then
        backup::file "${dropin}"
        utils::run_cmd "rm -f \"${dropin}\""
    fi
    if ! sshd -t; then
        utils::log_error "sshd validation failed after removing ${dropin}"
        exit 1
    fi
    ssh::restart_sshd_and_verify
    utils::log_info "Removed wg-only sshd listener drop-in; sshd is back to standard listen behavior"
}

ssh::rotate_sshd_host_keys() {
  # Purpose: Rotate sshd host keys.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local ts backup_dir rotation_failed=0
    ts=$(date -u '+%Y%m%d%H%M%S')
    backup::ensure_backup_root
    backup_dir="${BACKUP_ROOT}/${SSH_HOSTKEY_BACKUP_CATEGORY}/${ts}"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would backup host keys to ${backup_dir}, regenerate with ssh-keygen -A, and restart sshd"
        return
    fi

    fs::ensure_dir "${backup_dir}" 0700 root root
    if ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
        utils::run_cmd "cp -a /etc/ssh/ssh_host_* \"${backup_dir}/\""
        BACKUP_PATHS+=("${backup_dir}")
        utils::log_info "Backed up existing ssh host keys to ${backup_dir}"
    else
        utils::log_warn "No existing ssh host keys found before rotation"
    fi

    if ! systemd::stop sshd; then
        utils::log_warn "Could not stop sshd for host key rotation; skipping rotation"
        return
    fi

    if ! utils::run_cmd "rm -f /etc/ssh/ssh_host_*"; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! utils::run_cmd "ssh-keygen -A"; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! systemd::start sshd; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! sshd -t; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! systemd::is_active sshd; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! ssh::__verify_sshd_port; then
        utils::log_warn "sshd port verification failed after host key rotation"
        rotation_failed=1
    fi

    if [[ ${rotation_failed} -eq 0 ]]; then
        utils::log_info "sshd is listening on port ${SSH_PORT} after host key rotation"
        utils::log_warn "Host keys rotated. Clients will see a host key change and must update known_hosts."
        ssh::_log_effective_crypto
        return
    fi

    utils::log_warn "Host key rotation failed; attempting to restore previous keys from ${backup_dir}"
    utils::run_cmd "rm -f /etc/ssh/ssh_host_*"
    if ls "${backup_dir}"/ssh_host_* >/dev/null 2>&1; then
        utils::run_cmd "cp -a \"${backup_dir}\"/ssh_host_* /etc/ssh/"
    fi
    if sshd -t && systemd::restart sshd && ssh::__verify_sshd_port; then
        utils::log_warn "Restored previous sshd host keys after rotation failure."
        ssh::_log_effective_crypto
        return
    fi
    utils::log_error "Restoration after failed host key rotation did not succeed; sshd may be unavailable."
    exit 1
}
