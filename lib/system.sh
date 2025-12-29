# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

configure_hostname() {
    if [[ -z "${SYSTEM_HOSTNAME}" ]]; then
        return
    fi
    run_cmd "hostnamectl set-hostname ${SYSTEM_HOSTNAME}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        return
    fi
    log_info "Hostname set to ${SYSTEM_HOSTNAME}"
}

configure_journald() {
    backup_file /etc/systemd/journald.conf
    write_file_atomic /etc/systemd/journald.conf < "${CONFIG_DIR}/journald.conf"
    run_cmd "systemctl restart systemd-journald"
}

configure_sysctl() {
    backup_file /etc/sysctl.d/99-hardening.conf
    write_file_atomic /etc/sysctl.d/99-hardening.conf < "${CONFIG_DIR}/sysctl_hardening.conf"
}

configure_vm_tuning_sysctl() {
    local dest=/etc/sysctl.d/99-vm-tuning.conf
    backup_file "${dest}"
    write_file_atomic "${dest}" < "${CONFIG_DIR}/vm-tuning.conf"
}

apply_sysctl_settings() {
    run_cmd "sysctl --system"
}

configure_tmp_mount() {
    backup_file /etc/systemd/system/tmp.mount
    write_file_atomic /etc/systemd/system/tmp.mount < "${CONFIG_DIR}/tmp.mount"
    run_cmd "systemctl daemon-reload"
    run_cmd "systemctl enable --now tmp.mount"
}

configure_zram() {
    local dest=/etc/systemd/zram-generator.conf
    backup_file "${dest}"
    write_file_atomic "${dest}" < "${CONFIG_DIR}/zram-generator.conf"
    run_cmd "systemctl daemon-reload"
    if ! run_cmd "systemctl restart systemd-zram-setup@zram0.service"; then
        log_warn "systemd-zram-setup@zram0.service not available; ensure zram-generator is installed and units exist."
    fi
}

enable_timesync() {
    run_cmd "systemctl enable --now systemd-timesyncd.service"
}

report_services() {
    log_info "Enabled services summary:"
    status_cmd "systemctl list-unit-files --type=service --state=enabled"
}

disable_units_from_config() {
    local list_file="${CONFIG_DIR}/disable-units.list"
    if [[ ! -f "${list_file}" ]]; then
        log_warn "Disable list missing at ${list_file}; skipping"
        return
    fi

    while IFS= read -r unit || [[ -n "${unit}" ]]; do
        unit=$(echo "${unit%%#*}" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
        if [[ -z "${unit}" ]]; then
            continue
        fi
        if [[ "${unit}" == *cloud-init* ]]; then
            log_warn "Skipping cloud-init unit ${unit}"
            continue
        fi
        local state
        state=$(systemctl is-enabled "${unit}" 2>/dev/null | tr -d '\r' || true)
        if [[ -z "${state}" ]]; then
            log_warn "Could not determine enable state for ${unit}; skipping"
            continue
        fi
        case "${state}" in
            enabled|enabled-runtime)
                if ! run_cmd "systemctl disable --now ${unit}"; then
                    log_warn "Failed to disable ${unit}; please review manually"
                fi
                ;;
            indirect)
                if ! run_cmd "systemctl disable --now ${unit}"; then
                    log_warn "Indirect unit ${unit} could not be disabled cleanly; please review manually"
                fi
                ;;
            static|disabled)
                if systemctl is-active --quiet "${unit}"; then
                    systemctl stop "${unit}" >/dev/null 2>&1 || true
                fi
                if [[ "${state}" == "static" ]]; then
                    log_info "${unit} is static; cannot be disabled via systemctl. Skipped disable."
                fi
                if [[ "${unit}" == "archlinux-keyring-wkd-sync.service" ]]; then
                    if systemctl is-active --quiet "archlinux-keyring-wkd-sync.timer"; then
                        systemctl stop "archlinux-keyring-wkd-sync.timer" >/dev/null 2>&1 || true
                        log_info "Stopped archlinux-keyring-wkd-sync.timer while service is inactive"
                    fi
                fi
                ;;
            *)
                log_warn "Unexpected enable state '${state}' for ${unit}; skipped"
                ;;
        esac
    done < "${list_file}"
}

ensure_default_target() {
    run_cmd "systemctl set-default multi-user.target"
    run_cmd "systemctl get-default"
}

verify_zram_swap() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would verify zram swap priority"
        return
    fi
    local swap_output zram_priority swapfile_priority
    swap_output=$(swapon --show --noheadings --raw --bytes 2>/dev/null || true)
    if [[ -z "${swap_output}" ]]; then
        log_warn "No active swap devices reported; zram may not be active."
        return
    fi
    zram_priority=$(echo "${swap_output}" | awk '$1 ~ /zram0/ {print $4}' | head -n1)
    swapfile_priority=$(echo "${swap_output}" | awk '$1 ~ /swapfile/ {print $4}' | head -n1)
    if echo "${swap_output}" | grep -q '/dev/zram0'; then
        log_info "zram device detected in swap list."
    else
        log_warn "zram device /dev/zram0 not present in swap list."
    fi
    if [[ -n "${zram_priority}" && -n "${swapfile_priority}" ]]; then
        if (( zram_priority > swapfile_priority )); then
            log_info "zram priority (${zram_priority}) is higher than swapfile (${swapfile_priority})."
        else
            log_warn "zram priority (${zram_priority:-unset}) is not higher than swapfile (${swapfile_priority:-unset})."
        fi
    else
        log_warn "Could not determine swap priorities for zram and swapfile; review swapon output manually."
    fi
}
