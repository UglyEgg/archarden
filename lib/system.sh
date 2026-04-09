# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

system::configure_hostname() {
  # Purpose: Configure hostname.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -z "${SYSTEM_HOSTNAME}" ]]; then
        return
    fi
    utils::run_cmd "hostnamectl set-hostname ${SYSTEM_HOSTNAME}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        return
    fi
    utils::log_info "Hostname set to ${SYSTEM_HOSTNAME}"
}

system::configure_journald() {
  # Purpose: Configure journald.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local tmp
    backup::file /etc/systemd/journald.conf

    tmp=$(mktemp)
    cp -f "${CONFIG_DIR}/journald.conf" "${tmp}"

    # By default, Archarden does not ingest kernel audit events into journald.
    # Users opting in via --enable-auditd can keep audit ingestion enabled.
    if [[ ${ENABLE_AUDITD} -eq 1 ]]; then
        printf '\nAudit=yes\n' >>"${tmp}"
    else
        printf '\nAudit=no\n' >>"${tmp}"
    fi

    utils::write_file_atomic /etc/systemd/journald.conf <"${tmp}"
    rm -f "${tmp}"
    systemd::restart systemd-journald
}

system::configure_sysctl() {
  # Purpose: Configure sysctl.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    backup::file /etc/sysctl.d/99-hardening.conf
    utils::write_file_atomic /etc/sysctl.d/99-hardening.conf < "${CONFIG_DIR}/sysctl_hardening.conf"
}

system::configure_vm_tuning_sysctl() {
  # Purpose: Configure vm tuning sysctl.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest=/etc/sysctl.d/99-vm-tuning.conf
    backup::file "${dest}"
    utils::write_file_atomic "${dest}" < "${CONFIG_DIR}/vm-tuning.conf"
}

system::apply_sysctl_settings() {
  # Purpose: Apply sysctl settings.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::run_cmd "sysctl --system"
}

system::configure_tmp_mount() {
  # Purpose: Configure tmp mount.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    backup::file /etc/systemd/system/tmp.mount
    utils::write_file_atomic /etc/systemd/system/tmp.mount < "${CONFIG_DIR}/tmp.mount"
    systemd::daemon_reload
    systemd::enable_now tmp.mount
}

system::configure_zram() {
  # Purpose: Configure zram.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest=/etc/systemd/zram-generator.conf
    backup::file "${dest}"
    utils::write_file_atomic "${dest}" < "${CONFIG_DIR}/zram-generator.conf"
    systemd::daemon_reload
    if ! systemd::restart systemd-zram-setup@zram0.service; then
        utils::log_warn "systemd-zram-setup@zram0.service not available; ensure zram-generator is installed and units exist."
    fi
}

system::enable_timesync() {
  # Purpose: Enable timesync.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    systemd::enable_now systemd-timesyncd.service
}

system::report_services() {
  # Purpose: Report services.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "Enabled services summary:"
    steps::status_cmd "systemctl list-unit-files --type=service --state=enabled"
}

system::disable_units_from_config() {
  # Purpose: Disable units from config.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local list_file="${CONFIG_DIR}/disable-units.list"
    if [[ ! -f "${list_file}" ]]; then
        utils::log_warn "Disable list missing at ${list_file}; skipping"
        return
    fi

    while IFS= read -r unit || [[ -n "${unit}" ]]; do
        unit=$(echo "${unit%%#*}" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')
        if [[ -z "${unit}" ]]; then
            continue
        fi
        if [[ "${unit}" == *cloud-init* ]]; then
            utils::log_warn "Skipping cloud-init unit ${unit}"
            continue
        fi
        local state
        state=$(systemctl is-enabled "${unit}" 2>/dev/null | tr -d '\r' || true)
        if [[ -z "${state}" ]]; then
            utils::log_warn "Could not determine enable state for ${unit}; skipping"
            continue
        fi
        case "${state}" in
            enabled|enabled-runtime)
                if ! systemd::disable_now "${unit}"; then
                    utils::log_warn "Failed to disable ${unit}; please review manually"
                fi
                ;;
            indirect)
                if ! systemd::disable_now "${unit}"; then
                    utils::log_warn "Indirect unit ${unit} could not be disabled cleanly; please review manually"
                fi
                ;;
            static|disabled)
                if systemctl is-active --quiet "${unit}"; then
                    systemctl stop "${unit}" >/dev/null 2>&1 || true
                fi
                if [[ "${state}" == "static" ]]; then
                    utils::log_info "${unit} is static; cannot be disabled via systemctl. Skipped disable."
                fi
                if [[ "${unit}" == "archlinux-keyring-wkd-sync.service" ]]; then
                    if systemctl is-active --quiet "archlinux-keyring-wkd-sync.timer"; then
                        systemctl stop "archlinux-keyring-wkd-sync.timer" >/dev/null 2>&1 || true
                        utils::log_info "Stopped archlinux-keyring-wkd-sync.timer while service is inactive"
                    fi
                fi
                ;;
            *)
                utils::log_warn "Unexpected enable state '${state}' for ${unit}; skipped"
                ;;
        esac
    done < "${list_file}"
}

system::ensure_default_target() {
  # Purpose: Ensure default target. (systemd)
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::run_cmd "systemctl set-default multi-user.target"
    utils::run_cmd "systemctl get-default"
}

system::verify_zram_swap() {
  # Purpose: Verify zram swap.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would verify zram swap priority"
        return
    fi
    local swap_output zram_priority swapfile_priority
    swap_output=$(swapon --show --noheadings --raw --bytes 2>/dev/null || true)
    if [[ -z "${swap_output}" ]]; then
        utils::log_warn "No active swap devices reported; zram may not be active."
        return
    fi
    zram_priority=$(echo "${swap_output}" | awk '$1 ~ /zram0/ {print $4}' | head -n1)
    swapfile_priority=$(echo "${swap_output}" | awk '$1 ~ /swapfile/ {print $4}' | head -n1)
    if echo "${swap_output}" | grep -q '/dev/zram0'; then
        utils::log_info "zram device detected in swap list."
    else
        utils::log_warn "zram device /dev/zram0 not present in swap list."
    fi
    if [[ -n "${zram_priority}" && -n "${swapfile_priority}" ]]; then
        if (( zram_priority > swapfile_priority )); then
            utils::log_info "zram priority (${zram_priority}) is higher than swapfile (${swapfile_priority})."
        else
            utils::log_warn "zram priority (${zram_priority:-unset}) is not higher than swapfile (${swapfile_priority:-unset})."
        fi
    else
        utils::log_warn "Could not determine swap priorities for zram and swapfile; review swapon output manually."
    fi
}


system::disable_mdns_llmnr() {
  # Purpose: Disable mDNS/LLMNR listeners that can expose UDP/TCP 5353/5355 publicly on some images.
  # Servers generally do not need multicast name resolution.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error.
  if [[ ${DRY_RUN} -eq 1 ]]; then
    utils::log_info "[DRY-RUN] Would disable mDNS/LLMNR services (avahi / systemd-resolved)"
    return 0
  fi

  # Disable Avahi if present.
  if utils::have_cmd systemctl; then
    if systemctl list-unit-files 2>/dev/null | grep -qE '^avahi-daemon\.service'; then
      utils::run_cmd "systemctl disable --now avahi-daemon.service avahi-daemon.socket 2>/dev/null || true"
    fi
  fi

  # Disable MulticastDNS + LLMNR in systemd-resolved if present.
  # Fresh Arch installs may ship systemd-resolved without /etc/systemd/resolved.conf
  # or /etc/systemd/resolved.conf.d existing yet, so keying this on unit presence is
  # more reliable than keying it on pre-existing config paths.
  if utils::have_cmd systemctl && systemctl list-unit-files 2>/dev/null | grep -qE '^systemd-resolved\.service'; then
    utils::run_cmd "install -d -m 0755 /etc/systemd/resolved.conf.d"
    cat >/etc/systemd/resolved.conf.d/archarden.conf <<'EOF'
[Resolve]
LLMNR=no
MulticastDNS=no
EOF
    chmod 0644 /etc/systemd/resolved.conf.d/archarden.conf

    # Restart if active; otherwise enablement is left to the distro image.
    utils::run_cmd "systemctl try-restart systemd-resolved.service 2>/dev/null || true"
  fi
}
