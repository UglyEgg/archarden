#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

creds::_prompt_secret_twice() {
    local label="$1" a b
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo "DRYRUN_${label// /_}_PASS"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        utils::log_error "Interactive password prompt requires a TTY."
        return 1
    fi
    while true; do
        read -r -s -p "Enter ${label} password: " a; echo
        read -r -s -p "Confirm ${label} password: " b; echo
        [[ -n "${a}" ]] || { utils::log_warn "${label} password cannot be empty."; continue; }
        [[ "${a}" == "${b}" ]] || { utils::log_warn "${label} passwords did not match. Try again."; continue; }
        echo "${a}"
        return 0
    done
}

creds::run() {
    utils::require_root || return 1

    local npm_email npm_pass kuma_user kuma_pass
    npm_email="${NPM_ADMIN_EMAIL:-$(secrets::read npm_admin_email 2>/dev/null || true)}"
    kuma_user="$(secrets::read kuma_admin_user 2>/dev/null || true)"
    [[ -n "${kuma_user}" ]] || kuma_user="admin"

    if [[ -z "${npm_email}" && -t 0 ]]; then
        read -r -p "Enter NPM admin email [admin@${SYSTEM_HOSTNAME:-archarden}.local]: " npm_email
        [[ -n "${npm_email}" ]] || npm_email="admin@${SYSTEM_HOSTNAME:-archarden}.local"
    fi
    [[ -n "${npm_email}" ]] || { utils::log_error "NPM admin email is required."; return 1; }

    npm_pass="$(creds::_prompt_secret_twice "NPM admin")"
    kuma_pass="$(creds::_prompt_secret_twice "Uptime Kuma admin")"

    secrets::write npm_admin_email "${npm_email}"
    secrets::write npm_admin_pass "${npm_pass}"
    secrets::write kuma_admin_user "${kuma_user}"
    secrets::write kuma_admin_pass "${kuma_pass}"

    NPM_ADMIN_EMAIL="${npm_email}"
    npm::ensure_admin_credentials
    kuma::ensure_admin_credentials

    utils::log_info "Credential rotation/re-apply complete."
}
