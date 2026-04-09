# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# systemd unit/timer installation for Gotify-related reporting/notifications.

gotify::install_units() {
  # Purpose: Install units.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local lib_dir=/usr/lib/archarden
    local os_report_service=/etc/systemd/system/archarden-os-report.service
    local os_report_timer=/etc/systemd/system/archarden-os-report.timer
    local container_scan_service=/etc/systemd/system/archarden-container-scan.service
    local container_scan_timer=/etc/systemd/system/archarden-container-scan.timer
    local portwatch_service=/etc/systemd/system/archarden-portwatch.service
    local portwatch_timer=/etc/systemd/system/archarden-portwatch.timer
    local container_events_service=/etc/systemd/system/archarden-container-events.service
    local gotify_proxycheck_service=/etc/systemd/system/archarden-gotify-proxycheck.service
    local gotify_proxycheck_timer=/etc/systemd/system/archarden-gotify-proxycheck.timer
    local fail2ban_summary_service=/etc/systemd/system/archarden-fail2ban-summary.service
    local fail2ban_summary_timer=/etc/systemd/system/archarden-fail2ban-summary.timer

    gotify::_ensure_lib_dir
    utils::install_template_root_file "templates/gotify/os_update_report.sh.tmpl" "${lib_dir}/os_update_report.sh" 0750 root root

    utils::install_template_root_file "templates/gotify/container_update_scan.sh.tmpl" "${lib_dir}/container_update_scan.sh" 0750 root root

    utils::install_template_root_file "templates/gotify/public_listener_check.sh.tmpl" "${lib_dir}/public_listener_check.sh" 0750 root root

    utils::install_template_root_file "templates/gotify/container_event_watch.sh.tmpl" "${lib_dir}/container_event_watch.sh" 0750 root root

    utils::install_template_root_file "templates/gotify/gotify_proxy_check.sh.tmpl" "${lib_dir}/gotify_proxy_check.sh" 0750 root root

    utils::install_template_root_file "templates/gotify/fail2ban_daily_summary.sh.tmpl" "${lib_dir}/fail2ban_daily_summary.sh" 0750 root root

    utils::install_template_root_file "templates/systemd/system/archarden-os-report.service.tmpl" "${os_report_service}" 0644 root root "LIB_DIR=${lib_dir}"

    utils::install_template_root_file "templates/systemd/system/archarden-os-report.timer.tmpl" "${os_report_timer}" 0644 root root

    utils::install_template_root_file "templates/systemd/system/archarden-container-scan.service.tmpl" "${container_scan_service}" 0644 root root "LIB_DIR=${lib_dir}"

    utils::install_template_root_file "templates/systemd/system/archarden-container-scan.timer.tmpl" "${container_scan_timer}" 0644 root root

    utils::install_template_root_file "templates/systemd/system/archarden-portwatch.service.tmpl" "${portwatch_service}" 0644 root root "LIB_DIR=${lib_dir}"

    utils::install_template_root_file "templates/systemd/system/archarden-portwatch.timer.tmpl" "${portwatch_timer}" 0644 root root

    utils::install_template_root_file "templates/systemd/system/archarden-container-events.service.tmpl" "${container_events_service}" 0644 root root "LIB_DIR=${lib_dir}"

    utils::install_template_root_file "templates/systemd/system/archarden-gotify-proxycheck.service.tmpl" "${gotify_proxycheck_service}" 0644 root root "LIB_DIR=${lib_dir}"

    utils::install_template_root_file "templates/systemd/system/archarden-gotify-proxycheck.timer.tmpl" "${gotify_proxycheck_timer}" 0644 root root

    utils::install_template_root_file "templates/systemd/system/archarden-fail2ban-summary.service.tmpl" "${fail2ban_summary_service}" 0644 root root "LIB_DIR=${lib_dir}"

    utils::install_template_root_file "templates/systemd/system/archarden-fail2ban-summary.timer.tmpl" "${fail2ban_summary_timer}" 0644 root root
}
