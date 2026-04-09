# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Gotify notification orchestration. Sources gotify_api/install/units and exposes gotify::* entry points.

{
    # shellcheck disable=SC2164
    __gotify_notify_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/gotify_api.sh
    source "${__gotify_notify_lib_dir}/gotify_api.sh"
    # shellcheck source=lib/gotify_install.sh
    source "${__gotify_notify_lib_dir}/gotify_install.sh"
    # shellcheck source=lib/gotify_units.sh
    source "${__gotify_notify_lib_dir}/gotify_units.sh"
    unset __gotify_notify_lib_dir
}

gotify::ensure_container_running() {
  # Purpose: Ensure container running. (systemd)
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -n "${GOTIFY_PUBLIC_HOST:-}" ]]; then
        if ! podman_runtime::podmin_systemctl is-active gotify.service >/dev/null 2>&1; then
            utils::log_warn "Gotify service is not active for ${PODMAN_USER}; notifications may not be configurable yet."
        fi
    fi
}

gotify::ensure_token() {
  # Purpose: Ensure token.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local env_file=/etc/archarden/notify-gotify.env
    fs::ensure_dir /etc/archarden 0700

    local gotify_url="" external_url="" token=""
    if [[ -n "${GOTIFY_PUBLIC_HOST:-}" ]]; then
        external_url="https://${GOTIFY_PUBLIC_HOST}"

        # Prefer internal container access for setup so we do not depend on NPM/proxy readiness.
        gotify_url="$(gotify_api::internal_base_url 2>/dev/null || true)"
        if [[ -z "${gotify_url}" ]]; then
            # Fallback if internal IP isn't available yet.
            gotify_url="${external_url}"
        fi

        local admin_pass
        admin_user="$(secrets::ensure_gotify_admin_user)"
        admin_pass="$(secrets::ensure_gotify_admin_pass)"

        if gotify_api::wait_ready; then
            if ! gotify_api::basic_auth_ok "${admin_user}" "${admin_pass}"; then
                # If this is an existing deployment with default creds, rotate immediately.
                if gotify_api::basic_auth_ok "${admin_user}" "admin"; then
                    if gotify_api::set_user_password_via_api "${admin_user}" "admin" "${admin_pass}"; then
                        utils::log_info "Rotated Gotify admin password from default."
                    else
                        utils::log_warn "Unable to rotate Gotify admin password via API; manual intervention may be required."
                    fi
                else
                    utils::log_warn "Unable to authenticate to Gotify as admin; cannot ensure admin password."
                fi
            fi

            token=$(gotify_api::get_or_create_app_token "${admin_pass}" || true)
            if [[ -z "${token}" ]]; then
                utils::log_warn "Unable to create or fetch Gotify application token; notifications will remain disabled."
            fi
        else
            utils::log_warn "Gotify did not become ready; notifications will remain disabled."
        fi
    fi

    backup::file "${env_file}" || true
    utils::write_file_atomic "${env_file}" <<EOT
# Gotify endpoint and access token (leave blank to disable notifications)
GOTIFY_URL=${gotify_url}
GOTIFY_TOKEN=${token}
# Optional external URL (proxied via NPM) used for reachability checks
GOTIFY_EXTERNAL_URL=${external_url}
# Optional priority (default 5)
GOTIFY_PRIORITY=5
EOT
    utils::ensure_file_permissions "${env_file}" 0600 root root
}

gotify::verify() {
  # Purpose: Verify the requested state.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    systemd::daemon_reload
    systemd::enable_now archarden-os-report.timer
    systemd::enable_now archarden-container-scan.timer
    systemd::enable_now archarden-portwatch.timer
    systemd::enable_now archarden-container-events.service
    systemd::enable_now archarden-gotify-proxycheck.timer
    systemd::enable_now archarden-fail2ban-summary.timer
}
