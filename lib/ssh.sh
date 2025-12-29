# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

configure_sshd() {
    mkdir -p "${SSHD_CONFIG_DIR}"
    run_cmd "ssh-keygen -A"
    backup_file "${SSHD_HARDENING_DROPIN}"
    backup_file "${SSHD_CRYPTO_DROPIN}"
    sed "s/__SSH_PORT__/${SSH_PORT}/g" "${CONFIG_DIR}/sshd_hardening.conf" | write_file_atomic "${SSHD_HARDENING_DROPIN}"
    write_file_atomic "${SSHD_CRYPTO_DROPIN}" < "${CONFIG_DIR}/sshd_crypto_hardening.conf"
    if [ "${DRY_RUN}" -eq 0 ]; then
        if ! sshd -t; then
            log_error "sshd configuration failed validation"
            restore_sshd_dropins
            exit 1
        fi
    else
        log_info "[DRY-RUN] Skipping sshd validation"
    fi
}

ensure_admin_sudoers() {
    local sudoers_file=/etc/sudoers.d/90-archarden-ssh-user tmp
    tmp=$(mktemp)
    printf "%s ALL=(ALL) NOPASSWD: ALL\n" "${USER_NAME}" > "${tmp}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would install sudoers entry at ${sudoers_file} for ${USER_NAME}"
        rm -f "${tmp}"
        return
    fi
    backup_file "${sudoers_file}"
    install -D -m 0440 "${tmp}" "${sudoers_file}"
    chown root:root "${sudoers_file}"
    rm -f "${tmp}"
}

create_admin_user() {
    if [[ -z "${USER_NAME}" ]]; then
        return
    fi
    if id -u "${USER_NAME}" >/dev/null 2>&1; then
        log_info "User ${USER_NAME} already exists"
    else
        run_cmd "useradd -m -G wheel,ssh -s /bin/bash ${USER_NAME}"
        log_info "Created user ${USER_NAME} and added to wheel,ssh"
    fi
    ensure_user_in_group "${USER_NAME}" wheel
    ensure_user_in_group "${USER_NAME}" ssh
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would lock password for ${USER_NAME}"
    else
        run_cmd "passwd -l ${USER_NAME}"
    fi
    USER_HOME=$(getent passwd "${USER_NAME}" | cut -d: -f6)
    if [[ -z "${USER_HOME}" ]]; then
        log_error "Unable to determine home for ${USER_NAME}"
        exit 1
    fi
    if [[ -n "${PUBKEY_FILE}" ]]; then
        PUBKEY_VALUE=$(cat "${PUBKEY_FILE}")
    fi
    if [[ -n "${PUBKEY_VALUE}" ]]; then
        local ssh_dir="${USER_HOME}/.ssh"
        run_cmd "install -d -m 700 -o ${USER_NAME} -g ${USER_NAME} ${ssh_dir}"
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
            log_info "[DRY-RUN] Would add key for ${USER_NAME}"
        fi
    else
        log_warn "No public key provided for ${USER_NAME}; ensure key-based auth manually."
    fi

    ensure_admin_sudoers
}

ensure_ssh_group() {
    if getent group ssh >/dev/null 2>&1; then
        local current_gid
        current_gid=$(getent group ssh | cut -d: -f3)
        if (( current_gid < 1000 )); then
            log_info "SSH access group 'ssh' already exists as a system group (gid ${current_gid})"
            return
        fi

        local new_gid
        if ! new_gid=$(next_available_system_gid); then
            log_error "Unable to find a free system gid (<1000) to convert 'ssh' group"
            exit 1
        fi

        run_cmd "groupmod -g ${new_gid} ssh"
        log_warn "Converted existing 'ssh' group to system gid ${new_gid}"
        return
    fi

    run_cmd "groupadd -r ssh"
    log_info "Created system group 'ssh' for SSH access control"
}

ensure_user_in_group() {
    local user="$1" group="$2"
    if ! id -u "${user}" >/dev/null 2>&1; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            log_info "[DRY-RUN] Would ensure ${user} is in group ${group}"
            return
        fi
        log_error "User ${user} does not exist; cannot add to ${group}"
        exit 1
    fi
    if id -nG "${user}" | tr ' ' '\n' | grep -qx "${group}"; then
        return
    fi
    run_cmd "usermod -aG ${group} ${user}"
    log_info "Added ${user} to ${group}"
}

restore_sshd_dropins() {
    local restored=0 dropin latest_backup backup_pattern
    for dropin in "${SSHD_HARDENING_DROPIN}" "${SSHD_CRYPTO_DROPIN}"; do
        latest_backup=""
        if [[ -n "${BACKUP_ROOT:-}" ]]; then
            backup_pattern="${BACKUP_ROOT}/configs/${dropin#/}"
            latest_backup=$(ls -1t "${backup_pattern}".*.bak 2>/dev/null | head -n1 || true)
        fi
        if [[ -z "${latest_backup}" ]]; then
            latest_backup=$(ls -1t "${dropin}".*.bak 2>/dev/null | head -n1 || true)
        fi
        if [[ -n "${latest_backup}" ]]; then
            run_cmd "cp -p \"${latest_backup}\" \"${dropin}\""
            restored=1
        elif [[ -f "${dropin}" ]]; then
            run_cmd "rm -f ${dropin}"
            restored=1
            log_warn "Removed ${dropin} after failure; no backup was available."
        fi
    done
    if [[ ${restored} -eq 1 ]]; then
        log_warn "Restored previous sshd drop-ins from backups after failure."
    fi
    return ${restored}
}

log_sshd_effective_crypto() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would log effective sshd crypto configuration"
        return
    fi
    status_cmd "sshd -T | grep -E 'kexalgorithms|ciphers|macs|hostkeyalgorithms|pubkeyacceptedalgorithms' || true"
}

verify_sshd_port() {
    if ss -tulpn | grep -q ":${SSH_PORT}"; then
        return 0
    fi
    return 1
}

restart_sshd_and_verify() {
    if [ "${DRY_RUN}" -eq 0 ]; then
        if run_cmd "systemctl restart sshd"; then
            if verify_sshd_port; then
                log_sshd_effective_crypto
                return
            fi
            log_error "sshd is not listening on port ${SSH_PORT} after restart"
        else
            log_error "sshd restart failed"
        fi
        log_warn "Attempting to restore previous sshd configuration after restart failure"
        restore_sshd_dropins
        if sshd -t && run_cmd "systemctl restart sshd" && verify_sshd_port; then
            log_warn "Restored previous sshd drop-ins after restart failure"
            log_sshd_effective_crypto
            return
        fi
        log_error "Unable to recover sshd service after restart failure; manual intervention required."
        exit 1
    else
        log_info "[DRY-RUN] Would restart sshd and verify port ${SSH_PORT}"
    fi
}

rotate_sshd_host_keys() {
    local ts backup_dir rotation_failed=0
    ts=$(date -u '+%Y%m%d%H%M%S')
    ensure_backup_root
    backup_dir="${BACKUP_ROOT}/${SSH_HOSTKEY_BACKUP_CATEGORY}/${ts}"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would backup host keys to ${backup_dir}, regenerate with ssh-keygen -A, and restart sshd"
        return
    fi

    run_cmd "install -d -m 0700 -o root -g root \"${backup_dir}\""
    if ls /etc/ssh/ssh_host_* >/dev/null 2>&1; then
        run_cmd "cp -a /etc/ssh/ssh_host_* \"${backup_dir}/\""
        BACKUP_PATHS+=("${backup_dir}")
        log_info "Backed up existing ssh host keys to ${backup_dir}"
    else
        log_warn "No existing ssh host keys found before rotation"
    fi

    if ! run_cmd "systemctl stop sshd"; then
        log_warn "Could not stop sshd for host key rotation; skipping rotation"
        return
    fi

    if ! run_cmd "rm -f /etc/ssh/ssh_host_*"; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! run_cmd "ssh-keygen -A"; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! run_cmd "systemctl start sshd"; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! sshd -t; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! systemctl is-active --quiet sshd; then
        rotation_failed=1
    fi
    if [[ ${rotation_failed} -eq 0 ]] && ! verify_sshd_port; then
        log_warn "sshd port verification failed after host key rotation"
        rotation_failed=1
    fi

    if [[ ${rotation_failed} -eq 0 ]]; then
        log_info "sshd is listening on port ${SSH_PORT} after host key rotation"
        log_warn "Host keys rotated. Clients will see a host key change and must update known_hosts."
        log_sshd_effective_crypto
        return
    fi

    log_warn "Host key rotation failed; attempting to restore previous keys from ${backup_dir}"
    run_cmd "rm -f /etc/ssh/ssh_host_*"
    if ls "${backup_dir}"/ssh_host_* >/dev/null 2>&1; then
        run_cmd "cp -a \"${backup_dir}\"/ssh_host_* /etc/ssh/"
    fi
    if sshd -t && run_cmd "systemctl restart sshd" && verify_sshd_port; then
        log_warn "Restored previous sshd host keys after rotation failure."
        log_sshd_effective_crypto
        return
    fi
    log_error "Restoration after failed host key rotation did not succeed; sshd may be unavailable."
    exit 1
}
