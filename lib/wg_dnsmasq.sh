# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# dnsmasq integration for wg0 (split-horizon/internal DNS) extracted from lib/steps.sh.

wg_dnsmasq::__wait_for_wg0() {
  # Purpose: Wait briefly for wg0 to exist before restarting dnsmasq.
  # Inputs: None.
  # Outputs: Return 0 when wg0 exists; non-zero on timeout.
    local attempt
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        return 0
    fi
    for attempt in $(seq 1 20); do
        if ip link show wg0 >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wg_dnsmasq::__install_wg_refresh_dropin() {
  # Purpose: Ensure wg-quick refreshes dnsmasq after wg0 is brought up.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error.
    local dropin_path="/etc/systemd/system/wg-quick@wg0.service.d/archarden-dnsmasq-refresh.conf"
    utils::install_template_root_file \
        "templates/systemd/system/wg-quick@wg0.service.d/archarden-dnsmasq-refresh.conf.tmpl" \
        "${dropin_path}" 0644 root root
    systemd::daemon_reload
}

wg_dnsmasq::__upstream_resolv_file() {
  # Purpose: Upstream resolv file.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Prefer systemd-resolved's generated resolv.conf if present.
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
        echo "/run/systemd/resolve/resolv.conf"
        return 0
    fi
    echo "/etc/resolv.conf"
}

wg_dnsmasq::configure() {
  # Purpose: Configure the requested state. (systemd)
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Provide internal DNS for *.<server-shortname> over WireGuard only.
    wireguard::ensure_config_loaded

    local wg_ip domain_suffix upstream_resolv conf_dir conf_file
    wg_ip="${WG_INTERFACE_ADDRESS%%/*}"
    domain_suffix="$(wireguard::server_shortname)"
    upstream_resolv="$(wg_dnsmasq::__upstream_resolv_file)"
    conf_dir="/etc/dnsmasq.d"
    conf_file="${conf_dir}/archarden-wg0.conf"

    if [[ -z "${wg_ip}" || -z "${domain_suffix}" ]]; then
        utils::log_error "dnsmasq configuration requires WG_INTERFACE_ADDRESS and a server shortname"
        exit 1
    fi

    # Ensure dnsmasq loads /etc/dnsmasq.d/*.conf on Arch.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure dnsmasq includes conf-dir=/etc/dnsmasq.d,*.conf"
    else
        backup::file /etc/dnsmasq.conf
        utils::append_if_missing /etc/dnsmasq.conf "conf-dir=/etc/dnsmasq.d,*.conf"
    fi

    if [[ ${DRY_RUN} -eq 0 ]]; then
        fs::ensure_dir "${conf_dir}" 0755 root root
    else
        utils::log_info "[DRY-RUN] Would ensure ${conf_dir} exists"
    fi

    if [[ ${DRY_RUN} -eq 0 ]]; then
        backup::file "${conf_file}"
    fi

    wg_dnsmasq::__install_wg_refresh_dropin

    utils::write_file_atomic "${conf_file}" <<EOT
# Managed by archarden. Do not edit.

# Listen only on WireGuard.
interface=wg0
bind-dynamic

# Upstream resolvers come from the system resolver.
resolv-file=${upstream_resolv}

# Basic hygiene.
domain-needed
bogus-priv

# Internal admin names (VPN-only): npm.${domain_suffix}, kuma.${domain_suffix}, etc.
address=/.${domain_suffix}/${wg_ip}
EOT

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would enable and start dnsmasq.service"
        return 0
    fi

    systemd::enable_now dnsmasq.service
    if ! wg_dnsmasq::__wait_for_wg0; then
        utils::log_warn "wg0 did not appear before restarting dnsmasq; service may bind to loopback until wg0 is up"
    fi
    systemd::restart dnsmasq.service
    steps::run_status_capture "systemctl is-active dnsmasq" systemctl is-active dnsmasq.service
}
