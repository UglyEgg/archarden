# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

fail2ban::_ensure_sshd_local() {
  # Purpose: Ensure sshd local.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local target=/etc/fail2ban/jail.d/sshd.local
    local tmp_base tmp_other tmp_out current_section section_lower

    tmp_base=$(mktemp)
    tmp_other=$(mktemp)
    tmp_out=$(mktemp)

    sed "s/__SSH_PORT__/${SSH_PORT}/g" "${CONFIG_DIR}/fail2ban_sshd.local" > "${tmp_base}"

    if [[ -f "${target}" ]]; then
        current_section=""
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^\[([^]]+)\] ]]; then
                current_section="${BASH_REMATCH[1]}"
            fi
            section_lower=${current_section,,}
            if [[ "${section_lower}" != "default" && "${section_lower}" != "sshd" ]]; then
                echo "${line}" >>"${tmp_other}"
            fi
        done < "${target}"
    fi

    cat "${tmp_base}" > "${tmp_out}"
    if [[ -s "${tmp_other}" ]]; then
        echo >>"${tmp_out}"
        cat "${tmp_other}" >>"${tmp_out}"
    fi

    utils::write_file_atomic "${target}" < "${tmp_out}"
    rm -f "${tmp_base}" "${tmp_other}" "${tmp_out}"
    utils::run_cmd "chown root:root ${target}"
}



fail2ban::_ensure_nginx_local() {
  # Purpose: Ensure nginx jails local.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local target=/etc/fail2ban/jail.d/nginx.local
    local tmp_base tmp_other tmp_out current_section section_lower
    local npm_log_glob enable_flag

    # Nginx Proxy Manager runs rootless as podmin; its logs live inside the npm-data volume.
    npm_log_glob="/home/podmin/.local/share/containers/storage/volumes/npm-data/_data/logs/*.log"

    # Enable the jails only if the log directory exists to avoid fail2ban startup noise.
    if [[ -d "/home/podmin/.local/share/containers/storage/volumes/npm-data/_data/logs" ]]; then
        enable_flag="true"
    else
        enable_flag="false"
        utils::log_warn "NPM log directory not found; nginx fail2ban jails will be installed but disabled"
    fi

    tmp_base=$(mktemp)
    tmp_other=$(mktemp)
    tmp_out=$(mktemp)

    sed -e "s|__NPM_LOG_GLOB__|${npm_log_glob}|g" -e "s|__ENABLE__|${enable_flag}|g" "${CONFIG_DIR}/fail2ban_nginx.local" > "${tmp_base}"

    if [[ -f "${target}" ]]; then
        current_section=""
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^\[([^]]+)\] ]]; then
                current_section="${BASH_REMATCH[1]}"
            fi
            section_lower=${current_section,,}
            if [[ "${section_lower}" != "nginx-http-auth" && "${section_lower}" != "nginx-botsearch" ]]; then
                echo "${line}" >>"${tmp_other}"
            fi
        done < "${target}"
    fi

    cat "${tmp_base}" > "${tmp_out}"
    if [[ -s "${tmp_other}" ]]; then
        echo >>"${tmp_out}"
        cat "${tmp_other}" >>"${tmp_out}"
    fi

    utils::write_file_atomic "${target}" < "${tmp_out}"
    rm -f "${tmp_base}" "${tmp_other}" "${tmp_out}"
    utils::run_cmd "chown root:root ${target}"
}
fail2ban::_ensure_nginx_local() {
  # Purpose: Ensure nginx jails for public HTTP/HTTPS endpoints (NPM).
  # Inputs: None.
  # Outputs: Writes /etc/fail2ban/jail.d/nginx.local.
    local target=/etc/fail2ban/jail.d/nginx.local
    local tmp_base npm_log_glob enable_flag

    tmp_base=$(mktemp)

    npm_log_glob="/home/podmin/.local/share/containers/storage/volumes/npm-data/_data/logs/*.log"
    if ls ${npm_log_glob} >/dev/null 2>&1; then
        enable_flag=true
    else
        enable_flag=false
    fi

    sed -e "s#__NPM_LOG_GLOB__#${npm_log_glob}#g" -e "s#__ENABLE__#${enable_flag}#g" "${CONFIG_DIR}/fail2ban_nginx.local" > "${tmp_base}"
    utils::write_file_atomic "${target}" < "${tmp_base}"
    rm -f "${tmp_base}"
    utils::run_cmd "chown root:root ${target}"
}

fail2ban::_ensure_nginx_local() {
  # Purpose: Ensure nginx jails for public HTTP/HTTPS endpoints (NPM).
  # Inputs: None.
  # Outputs: Writes /etc/fail2ban/jail.d/nginx.local.
    local target=/etc/fail2ban/jail.d/nginx.local
    local tmp_base tmp_other tmp_out current_section section_lower
    local npm_log_glob enable

    tmp_base=$(mktemp)
    tmp_other=$(mktemp)
    tmp_out=$(mktemp)

    npm_log_glob="/home/podmin/.local/share/containers/storage/volumes/npm-data/_data/logs/*.log"
    enable="false"
    if ls ${npm_log_glob} >/dev/null 2>&1; then
        enable="true"
    fi

    sed -e "s#__NPM_LOG_GLOB__#${npm_log_glob}#g" -e "s#__ENABLE__#${enable}#g" "${CONFIG_DIR}/fail2ban_nginx.local" > "${tmp_base}"

    if [[ -f "${target}" ]]; then
        current_section=""
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^\[([^]]+)\] ]]; then
                current_section="${BASH_REMATCH[1]}"
            fi
            section_lower="${current_section,,}"
            if [[ "${section_lower}" != "nginx-http-auth" && "${section_lower}" != "nginx-botsearch" ]]; then
                echo "${line}" >>"${tmp_other}"
            fi
        done < "${target}"
    fi

    cat "${tmp_base}" > "${tmp_out}"
    if [[ -s "${tmp_other}" ]]; then
        echo >>"${tmp_out}"
        cat "${tmp_other}" >>"${tmp_out}"
    fi

    utils::write_file_atomic "${target}" < "${tmp_out}"
    rm -f "${tmp_base}" "${tmp_other}" "${tmp_out}"
    utils::run_cmd "chown root:root ${target}"
}

fail2ban::_ensure_nginx_local() {
    local target=/etc/fail2ban/jail.d/nginx.local
    local tmp_base
    local log_glob enable
    tmp_base=$(mktemp)
    log_glob="/home/podmin/.local/share/containers/storage/volumes/npm-data/_data/logs/*.log"
    enable=false
    if ls ${log_glob} >/dev/null 2>&1; then enable=true; fi
    sed "s#__NPM_LOG_GLOB__#${log_glob}#g; s#__ENABLE__#${enable}#g" "${CONFIG_DIR}/fail2ban_nginx.local" > "${tmp_base}"
    utils::write_file_atomic "${target}" < "${tmp_base}"
    rm -f "${tmp_base}"
    utils::run_cmd "chown root:root ${target}"
}

fail2ban::_ensure_defaults_local() {
  # Purpose: Ensure defaults local.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local target=/etc/fail2ban/jail.local
    local tmp_base tmp_other tmp_out current_section section_lower

    tmp_base=$(mktemp)
    tmp_other=$(mktemp)
    tmp_out=$(mktemp)

    cat "${CONFIG_DIR}/fail2ban_jail.local" > "${tmp_base}"

    if [[ -f "${target}" ]]; then
        current_section=""
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^\[([^]]+)\] ]]; then
                current_section="${BASH_REMATCH[1]}"
            fi
            section_lower=${current_section,,}
            if [[ "${section_lower}" != "default" ]]; then
                echo "${line}" >>"${tmp_other}"
            fi
        done < "${target}"
    fi

    cat "${tmp_base}" > "${tmp_out}"
    if [[ -s "${tmp_other}" ]]; then
        echo >>"${tmp_out}"
        cat "${tmp_other}" >>"${tmp_out}"
    fi

    utils::write_file_atomic "${target}" < "${tmp_out}"
    rm -f "${tmp_base}" "${tmp_other}" "${tmp_out}"
    utils::run_cmd "chown root:root ${target}"
}

fail2ban::configure() {
  # Purpose: Configure the requested state. (firewall)
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${ENABLE_FAIL2BAN} -eq 0 ]]; then
        utils::log_warn "Fail2ban disabled by flag"
        return
    fi
    backup::file /etc/fail2ban/jail.local
    backup::file /etc/fail2ban/jail.d/sshd.local
    backup::file /etc/fail2ban/jail.d/nginx.local
    fs::ensure_dir /etc/fail2ban/jail.d 0755
    fail2ban::_ensure_defaults_local
    fail2ban::_ensure_sshd_local
    fail2ban::_ensure_nginx_local
    systemd::enable_now fail2ban.service
    systemd::restart fail2ban.service
    if utils::have_cmd ufw; then
        if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
            utils::log_warn "ufw is not active; banaction=ufw will not take effect until ufw is enabled"
        else
            steps::run_status_capture "ufw status numbered" ufw status numbered
        fi
    fi
    steps::run_status_capture "fail2ban-client status" fail2ban-client status
    steps::run_status_capture "fail2ban-client status sshd" fail2ban-client status sshd
}
