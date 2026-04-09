# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# podmin user provisioning (subuid/subgid, userns sysctls, API group). Extracted from lib/podman_rootless.sh.

podmin_user::ensure_podmin_user() {
  # Purpose: Ensure podmin user.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local expected_home="/home/${PODMAN_USER}" current_home current_shell
    if id -u "${PODMAN_USER}" >/dev/null 2>&1; then
        utils::log_info "Podman runtime user ${PODMAN_USER} already exists"
        current_home=$(getent passwd "${PODMAN_USER}" | cut -d: -f6)
        current_shell=$(getent passwd "${PODMAN_USER}" | cut -d: -f7)
        if [[ "${current_home}" != "${expected_home}" ]]; then
            utils::run_cmd "usermod -d ${expected_home} -m ${PODMAN_USER}"
        fi
        if [[ "${current_shell}" != "/usr/bin/nologin" ]]; then
            utils::run_cmd "usermod -s /usr/bin/nologin ${PODMAN_USER}"
        fi
    else
        utils::run_cmd "useradd -m -d ${expected_home} -s /usr/bin/nologin ${PODMAN_USER}"
        utils::log_info "Created podman runtime user ${PODMAN_USER} with nologin shell"
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would lock password for ${PODMAN_USER}"
    else
        utils::run_cmd "passwd -l ${PODMAN_USER}"
    fi
    if getent group ssh >/dev/null 2>&1; then
        utils::run_cmd "gpasswd -d ${PODMAN_USER} ssh >/dev/null 2>&1 || true"
    fi
    if getent group wheel >/dev/null 2>&1; then
        utils::run_cmd "gpasswd -d ${PODMAN_USER} wheel >/dev/null 2>&1 || true"
    fi
    fs::ensure_dir "${expected_home}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
    PODMAN_HOME=$(getent passwd "${PODMAN_USER}" | cut -d: -f6)
    if [[ -z "${PODMAN_HOME}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            PODMAN_HOME="${expected_home}"
        else
            utils::log_error "Unable to determine home for ${PODMAN_USER}"
            exit 1
        fi
    fi
    if ! loginctl enable-linger "${PODMAN_USER}" >/dev/null 2>&1; then
        utils::log_warn "Could not enable linger for ${PODMAN_USER}; rootless services may not restart after reboot"
    fi
}

podmin_user::ensure_subordinate_ids() {
  # Purpose: Ensure subordinate ids.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local range_size=65536 user="${PODMAN_USER}"
    local subuid_file=/etc/subuid subgid_file=/etc/subgid
    local existing_start="" existing_size="" existing_start_gid="" existing_size_gid=""
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure subordinate ID ranges for ${user} in ${subuid_file} and ${subgid_file}"
        return 0
    fi

    if [[ -f "${subuid_file}" ]]; then
        if grep -q "^${user}:" "${subuid_file}" 2>/dev/null; then
            IFS=':' read -r _ existing_start existing_size < <(grep "^${user}:" "${subuid_file}" | head -n1)
        fi
    fi
    if [[ -f "${subgid_file}" ]]; then
        if grep -q "^${user}:" "${subgid_file}" 2>/dev/null; then
            IFS=':' read -r _ existing_start_gid existing_size_gid < <(grep "^${user}:" "${subgid_file}" | head -n1)
        fi
    fi

    if [[ -n "${existing_start}" && -n "${existing_start_gid}" ]]; then
        return 0
    fi

    local max_end_subuid max_end_subgid max_end start_range end_range start_to_use size_to_use
    max_end_subuid=$(podmin_user::__subordinate_id_max_end "${subuid_file}")
    max_end_subgid=$(podmin_user::__subordinate_id_max_end "${subgid_file}")
    max_end=${max_end_subuid}
    if (( max_end_subgid > max_end )); then
        max_end=${max_end_subgid}
    fi

    start_to_use="${existing_start:-${existing_start_gid}}"
    size_to_use="${existing_size:-${existing_size_gid:-${range_size}}}"
    if [[ -z "${start_to_use}" ]]; then
        start_to_use=$(( ((max_end + 1 + range_size - 1) / range_size) * range_size ))
        size_to_use=${range_size}
    fi
    start_range=${start_to_use}
    end_range=$((start_range + size_to_use - 1))

    if [[ ! -f "${subuid_file}" ]]; then
        utils::run_cmd "install -m 0644 /dev/null ${subuid_file}"
    fi
    if [[ ! -f "${subgid_file}" ]]; then
        utils::run_cmd "install -m 0644 /dev/null ${subgid_file}"
    fi

    if ! grep -q "^${user}:" "${subuid_file}" 2>/dev/null; then
        utils::run_cmd "bash -c 'echo \"${user}:${start_range}:${size_to_use}\" >> ${subuid_file}'"
        utils::log_info "Added subordinate UID range for ${user}: ${start_range}-${end_range}"
    fi
    if ! grep -q "^${user}:" "${subgid_file}" 2>/dev/null; then
        utils::run_cmd "bash -c 'echo \"${user}:${start_range}:${size_to_use}\" >> ${subgid_file}'"
        utils::log_info "Added subordinate GID range for ${user}: ${start_range}-${end_range}"
    fi
}

podmin_user::__subordinate_id_max_end() {
  # Purpose: Subordinate id max end.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local file="$1" max_end=0 line name start count end
    [[ -f "${file}" ]] || { echo 0; return; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        IFS=':' read -r name start count <<<"${line}"
        [[ -z "${name}" || -z "${start}" || -z "${count}" ]] && continue
        if [[ "${start}" =~ ^[0-9]+$ && "${count}" =~ ^[0-9]+$ ]]; then
            end=$((start + count - 1))
            if (( end > max_end )); then
                max_end=${end}
            fi
        fi
    done < "${file}"
    echo "${max_end}"
}

podmin_user::ensure_userns_sysctl() {
  # Purpose: Ensure userns sysctl.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local sysctl_file=/etc/sysctl.d/99-userns.conf
    local -a lines=()
    local value

    if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
        value=$(cat /proc/sys/kernel/unprivileged_userns_clone)
        if [[ "${value}" == "0" ]]; then
            lines+=("kernel.unprivileged_userns_clone=1")
        fi
    fi
    if [[ -f /proc/sys/user/max_user_namespaces ]]; then
        value=$(cat /proc/sys/user/max_user_namespaces)
        if [[ "${value}" == "0" ]]; then
            lines+=("user.max_user_namespaces=15000")
        fi
    fi

    if [[ ${#lines[@]} -eq 0 ]]; then
        return
    fi

    fs::ensure_dir /etc/sysctl.d 0755
    utils::write_file_atomic "${sysctl_file}" <<EOT
$(printf '%s\n' "${lines[@]}")
EOT
    steps::run_status_capture "sysctl --system" sysctl --system
}

podmin_user::ensure_podman_api_group() {
  # Purpose: Ensure podman api group.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if getent group "${PODMAN_API_GROUP}" >/dev/null 2>&1; then
        :
    else
        utils::run_cmd "groupadd -r ${PODMAN_API_GROUP}"
        utils::log_info "Created system group ${PODMAN_API_GROUP} for Podman API access"
    fi
    if [[ -n "${USER_NAME}" ]]; then
        ssh::ensure_user_in_group "${USER_NAME}" "${PODMAN_API_GROUP}"
    fi
}
