# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

notify::install_units() {
    local lib_dir=/usr/lib/archarden
    local os_report_service=/etc/systemd/system/archarden-os-report.service
    local os_report_timer=/etc/systemd/system/archarden-os-report.timer
    local container_scan_service=/etc/systemd/system/archarden-container-scan.service
    local container_scan_timer=/etc/systemd/system/archarden-container-scan.timer
    local portwatch_service=/etc/systemd/system/archarden-portwatch.service
    local portwatch_timer=/etc/systemd/system/archarden-portwatch.timer
    local container_events_service=/etc/systemd/system/archarden-container-events.service
    local ntfy_healthcheck_service=/etc/systemd/system/archarden-ntfy-healthcheck.service
    local ntfy_healthcheck_timer=/etc/systemd/system/archarden-ntfy-healthcheck.timer
    local fail2ban_summary_service=/etc/systemd/system/archarden-fail2ban-summary.service
    local fail2ban_summary_timer=/etc/systemd/system/archarden-fail2ban-summary.timer

    notify::_ensure_lib_dir
    utils::install_template_root_file "templates/notify/os_update_report.sh.tmpl" "${lib_dir}/os_update_report.sh" 0750 root root
    utils::install_template_root_file "templates/notify/container_update_scan.sh.tmpl" "${lib_dir}/container_update_scan.sh" 0750 root root
    utils::install_template_root_file "templates/notify/public_listener_check.sh.tmpl" "${lib_dir}/public_listener_check.sh" 0750 root root
    utils::install_template_root_file "templates/notify/container_event_watch.sh.tmpl" "${lib_dir}/container_event_watch.sh" 0750 root root
    utils::install_template_root_file "templates/notify/ntfy_health_check.sh.tmpl" "${lib_dir}/ntfy_health_check.sh" 0750 root root
    utils::install_template_root_file "templates/notify/fail2ban_daily_summary.sh.tmpl" "${lib_dir}/fail2ban_daily_summary.sh" 0750 root root

    utils::install_template_root_file "templates/systemd/system/archarden-os-report.service.tmpl" "${os_report_service}" 0644 root root "LIB_DIR=${lib_dir}"
    utils::install_template_root_file "templates/systemd/system/archarden-os-report.timer.tmpl" "${os_report_timer}" 0644 root root
    utils::install_template_root_file "templates/systemd/system/archarden-container-scan.service.tmpl" "${container_scan_service}" 0644 root root "LIB_DIR=${lib_dir}"
    utils::install_template_root_file "templates/systemd/system/archarden-container-scan.timer.tmpl" "${container_scan_timer}" 0644 root root
    utils::install_template_root_file "templates/systemd/system/archarden-portwatch.service.tmpl" "${portwatch_service}" 0644 root root "LIB_DIR=${lib_dir}"
    utils::install_template_root_file "templates/systemd/system/archarden-portwatch.timer.tmpl" "${portwatch_timer}" 0644 root root
    utils::install_template_root_file "templates/systemd/system/archarden-container-events.service.tmpl" "${container_events_service}" 0644 root root "LIB_DIR=${lib_dir}"
    utils::install_template_root_file "templates/systemd/system/archarden-ntfy-healthcheck.service.tmpl" "${ntfy_healthcheck_service}" 0644 root root "LIB_DIR=${lib_dir}"
    utils::install_template_root_file "templates/systemd/system/archarden-ntfy-healthcheck.timer.tmpl" "${ntfy_healthcheck_timer}" 0644 root root
    utils::install_template_root_file "templates/systemd/system/archarden-fail2ban-summary.service.tmpl" "${fail2ban_summary_service}" 0644 root root "LIB_DIR=${lib_dir}"
    utils::install_template_root_file "templates/systemd/system/archarden-fail2ban-summary.timer.tmpl" "${fail2ban_summary_timer}" 0644 root root
}

notify::enable_units() {
    systemd::daemon_reload
    systemd::enable_now archarden-os-report.timer
    systemd::enable_now archarden-container-scan.timer
    systemd::enable_now archarden-portwatch.timer
    systemd::enable_now archarden-container-events.service
    systemd::enable_now archarden-ntfy-healthcheck.timer
    systemd::enable_now archarden-fail2ban-summary.timer
}
