# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

ensure_fail2ban_sshd_local() {
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

    write_file_atomic "${target}" < "${tmp_out}"
    rm -f "${tmp_base}" "${tmp_other}" "${tmp_out}"
    run_cmd "chown root:root ${target}"
}

ensure_fail2ban_defaults_local() {
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

    write_file_atomic "${target}" < "${tmp_out}"
    rm -f "${tmp_base}" "${tmp_other}" "${tmp_out}"
    run_cmd "chown root:root ${target}"
}

configure_fail2ban() {
    if [[ ${ENABLE_FAIL2BAN} -eq 0 ]]; then
        log_warn "Fail2ban disabled by flag"
        return
    fi
    backup_file /etc/fail2ban/jail.local
    backup_file /etc/fail2ban/jail.d/sshd.local
    run_cmd "install -d -m 0755 /etc/fail2ban/jail.d"
    ensure_fail2ban_defaults_local
    ensure_fail2ban_sshd_local
    run_cmd "systemctl enable --now fail2ban.service"
    run_cmd "systemctl restart fail2ban.service"
    if command -v ufw >/dev/null 2>&1; then
        if ! ufw status 2>/dev/null | grep -qi "Status: active"; then
            log_warn "ufw is not active; banaction=ufw will not take effect until ufw is enabled"
        else
            run_status_capture "ufw status numbered" ufw status numbered
        fi
    fi
    run_status_capture "fail2ban-client status" fail2ban-client status
    run_status_capture "fail2ban-client status sshd" fail2ban-client status sshd
}
