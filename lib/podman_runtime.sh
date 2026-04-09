# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Rootless Podman runtime helpers (user manager + socket readiness + podman wrappers). Extracted from lib/podman_rootless.sh.

podman_runtime::podmin_systemctl() {
  # Purpose: Podmin systemctl.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local uid runtime_dir err_file err_msg attempt home_dir subcmd

    PODMIN_SYSTEMCTL_LAST_ERR=""
    subcmd="${1:-}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] (as ${PODMAN_USER}) systemctl --user --machine=${PODMAN_USER}@.host $*"
        return 0
    fi

    if ! podman_runtime::ensure_podmin_user_manager; then
        utils::log_warn "User manager unavailable for ${PODMAN_USER}; cannot run systemctl --user actions"
        return 1
    fi

    uid="${PODMAN_UID}"
    runtime_dir="/run/user/${uid}"


    if [[ "${subcmd}" == "cat" ]]; then
        # systemctl(1) does not support remote "cat" via --machine transport.
        err_msg="Cannot remotely cat units."
        PODMIN_SYSTEMCTL_LAST_ERR="${err_msg}"
        goto_fallback=1
    else
        goto_fallback=0
    fi

    if [[ ${goto_fallback} -eq 0 ]]; then
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        err_file=$(mktemp)
        if systemctl --user --machine="${PODMAN_USER}@.host" "$@" >/dev/null 2>"${err_file}"; then
            rm -f "${err_file}"
            return 0
        fi
        err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
        rm -f "${err_file}"
        if [[ "${err_msg}" =~ (Failed\ to\ connect|Connection\ refused|No\ such\ file|Transport\ endpoint\ is\ not\ connected) ]]; then
            sleep 0.5
            continue
        fi
        break
    done
    fi

    PODMIN_SYSTEMCTL_LAST_ERR="${err_msg:-unknown}"

    utils::log_warn "podmin systemctl (machine) failed: ${err_msg:-unknown}; retrying with direct user bus"

    if [[ ! -S "${runtime_dir}/bus" ]]; then
        utils::log_warn "User bus not present at ${runtime_dir}/bus; cannot use direct fallback for systemctl --user"
        return 1
    fi

    home_dir="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"

    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        err_file=$(mktemp)
        if XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" HOME="${home_dir}" runuser -u "${PODMAN_USER}" -- systemctl --user "$@" >/dev/null 2>"${err_file}"; then
            rm -f "${err_file}"
            return 0
        fi
        err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
        rm -f "${err_file}"
        if [[ "${err_msg}" =~ (Failed\ to\ connect|No\ such\ file) ]]; then
            sleep 0.5
            continue
        fi
        break
    done

    PODMIN_SYSTEMCTL_LAST_ERR="${err_msg:-unknown}"
    utils::log_warn "podmin systemctl (fallback) failed: ${err_msg:-unknown}; rootless services may not be active"
    return 1
}

podman_runtime::ensure_podmin_user_manager() {
  # Purpose: Ensure podmin user manager.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local runtime_dir err_file err_msg attempts sleep_s i
    if [[ ${ENSURED_PODMIN_MANAGER} -eq 1 ]]; then
        return 0
    fi
    if [[ -z "${PODMAN_UID}" ]]; then
        PODMAN_UID=$(id -u "${PODMAN_USER}")
    fi
    runtime_dir="/run/user/${PODMAN_UID}"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Ensuring user manager for ${PODMAN_USER} (uid ${PODMAN_UID})"
        return 0
    fi

    if ! loginctl enable-linger "${PODMAN_USER}" >/dev/null 2>&1; then
        utils::log_warn "Could not enable linger for ${PODMAN_USER}; rootless services may not persist across reboots"
    fi

    err_file=$(mktemp)
    if ! systemctl start "user@${PODMAN_UID}.service" >/dev/null 2>"${err_file}"; then
        err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
        if [[ -n "${err_msg}" ]]; then
            utils::log_warn "Could not start user@${PODMAN_UID}.service for ${PODMAN_USER}: ${err_msg}"
        fi
    fi
    rm -f "${err_file}"

    attempts=40
    sleep_s=0.25
    for ((i=0; i<attempts; i++)); do
        if systemctl is-active --quiet "user@${PODMAN_UID}.service" && [[ -d "${runtime_dir}" ]]; then
            break
        fi
        sleep "${sleep_s}"
    done

    if ! systemctl is-active --quiet "user@${PODMAN_UID}.service"; then
        utils::log_error "User manager not active for ${PODMAN_USER} (user@${PODMAN_UID}.service failed to start). Skipping rootless Podman setup."
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"user manager not active for ${PODMAN_USER}"}
        return 1
    fi

    if [[ ! -d "${runtime_dir}" ]]; then
        utils::log_warn "Runtime directory ${runtime_dir} missing for ${PODMAN_USER}; systemd-logind may not be managing the session runtime yet."
    fi

    # The user bus is required only for the direct 'systemctl --user' fallback path. The primary
    # control path uses 'systemctl --user --machine=${PODMAN_USER}@.host'.
    if [[ ! -S "${runtime_dir}/bus" ]]; then
        utils::log_warn "User bus missing at ${runtime_dir}/bus for ${PODMAN_USER}. Will rely on the --machine control path; fallback may not work yet."
    fi

    # Even once user@UID.service is active, systemctl's machine transport can take a moment
    # to become ready on slower VPS bootstraps. Treat this as a readiness concern, not a fatal error.
    attempts=80
    sleep_s=0.25
    for ((i=0; i<attempts; i++)); do
        if systemctl --user --machine="${PODMAN_USER}@.host" show-environment >/dev/null 2>&1; then
            break
        fi
        sleep "${sleep_s}"
    done
    if ! systemctl --user --machine="${PODMAN_USER}@.host" show-environment >/dev/null 2>&1; then
        utils::log_warn "systemctl --user --machine=${PODMAN_USER}@.host not ready yet; rootless unit management may be temporarily flaky."
    fi

    ENSURED_PODMIN_MANAGER=1
    return 0
}

podman_runtime::ensure_podmin_podman_socket() {
  # Purpose: Ensure podmin podman socket.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local systemd_dir runtime_dir socket_path home_dir
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping podman.socket setup because Podman prerequisites are not satisfied."
        return 1
    fi
    podman_runtime::ensure_podmin_user_manager || return 1
    home_dir="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    runtime_dir="/run/user/${PODMAN_UID}"
    socket_path="${runtime_dir}/podman/podman.sock"

    if ! podman_runtime::podmin_systemctl cat podman.socket >/dev/null 2>&1; then
        systemd_dir="${home_dir}/.config/systemd/user"
        fs::ensure_dir "${systemd_dir}" 0700 "${PODMAN_USER}" "${PODMAN_USER}"
        utils::write_file_atomic "${systemd_dir}/podman.socket" <<'EOT'
[Socket]
ListenStream=%t/podman/podman.sock
SocketMode=0660

[Install]
WantedBy=sockets.target
EOT
        utils::write_file_atomic "${systemd_dir}/podman.service" <<'EOT'
[Service]
ExecStart=/usr/bin/podman system service --time=0 unix://%t/podman/podman.sock
KillMode=process
EOT
        utils::ensure_file_permissions "${systemd_dir}/podman.socket" 0644 "${PODMAN_USER}"
        utils::ensure_file_permissions "${systemd_dir}/podman.service" 0644 "${PODMAN_USER}"
    fi

    podman_runtime::podmin_systemctl daemon-reload || true
    if ! podman_runtime::podmin_systemctl enable --now podman.socket; then
        utils::log_warn "Could not enable podman.socket for ${PODMAN_USER}; Podman API proxy will be skipped."
        return 1
    fi
    local i
    for ((i=0; i<40; i++)); do
        if [[ -S "${socket_path}" ]]; then
            return 0
        fi
        sleep 0.25
    done
    utils::log_warn "Podman socket not found at ${socket_path} after enabling podman.socket"
    return 1

}

podman_runtime::podmin_podman_info() {
  # Purpose: Podmin podman info.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local runtime_dir err_file output rc=0 err_msg home_dir
	home_dir="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would run podman info as ${PODMAN_USER}"
        echo "runc"
        return 0
    fi
    podman_runtime::ensure_podmin_user_manager || return 1
    runtime_dir="/run/user/${PODMAN_UID}"
    err_file=$(mktemp)
    output=$(runuser -u "${PODMAN_USER}" -- bash -c "cd \"${home_dir}\" && exec env HOME=\"${home_dir}\" XDG_RUNTIME_DIR=\"${runtime_dir}\" podman info --format '{{.Host.OCIRuntime.Name}}'" 2>"${err_file}")
    rc=$?
    err_msg=$(tr -d '\r' < "${err_file}")
    rm -f "${err_file}"
    output=$(echo "${output}" | tr -d '\r')
    if [[ ${rc} -ne 0 ]]; then
        utils::log_error "podman info failed for ${PODMAN_USER}: ${err_msg:-unknown error}"
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"podman info failed: ${err_msg:-unknown error}"}
        return ${rc}
    fi
    echo "${output}"
}

podman_runtime::podmin_podman() {
  # Purpose: Podmin podman.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local home_dir runtime_dir
	home_dir="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] (as ${PODMAN_USER}) podman $*"
        return 0
    fi
    podman_runtime::ensure_podmin_user_manager || return 1
    runtime_dir="/run/user/${PODMAN_UID}"

    # runuser preserves the caller's working directory. If the caller is in /root (common
    # during Phase 1), the unprivileged podmin user cannot chdir there and Podman calls fail
    # with: "cannot chdir to /root: Permission denied".
    runuser -u "${PODMAN_USER}" -- bash -c "cd \"${home_dir}\" && exec env HOME=\"${home_dir}\" XDG_RUNTIME_DIR=\"${runtime_dir}\" podman \"\$@\"" -- "$@"
}

podman_runtime::_ensure_containers_runtime_config() {
  # Purpose: Ensure containers runtime config.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local target="$1" owner="${2:-root}" group="${3:-root}"
    local runtime_line='runtime = "runc"'
    local tmp in_engine=0 runtime_set=0 found_engine=0
    tmp=$(mktemp)

    fs::ensure_parent_dir "${target}" 0755 "${owner}" "${group}"

    if [[ -f "${target}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^\[.*\] ]]; then
                if [[ ${in_engine} -eq 1 && ${runtime_set} -eq 0 ]]; then
                    echo "${runtime_line}" >>"${tmp}"
                fi
                in_engine=0
            fi
            if [[ "${line}" =~ ^\[engine\] ]]; then
                found_engine=1
                in_engine=1
                runtime_set=0
            fi
            if [[ ${in_engine} -eq 1 && "${line}" =~ ^runtime[[:space:]]*= ]]; then
                line=${runtime_line}
                runtime_set=1
            fi
            echo "${line}" >>"${tmp}"
        done < "${target}"
    fi

    if [[ ${in_engine} -eq 1 && ${runtime_set} -eq 0 ]]; then
        echo "${runtime_line}" >>"${tmp}"
    fi

    if [[ ${found_engine} -eq 0 ]]; then
        [[ -s "${tmp}" ]] && echo >>"${tmp}"
        {
            echo "[engine]"
            echo "${runtime_line}"
        } >>"${tmp}"
    fi

    utils::write_file_atomic "${target}" < "${tmp}"
    rm -f "${tmp}"
    if [[ "${owner}" != "root" || "${group}" != "root" ]]; then
        utils::run_cmd "chown ${owner}:${group} ${target}"
    fi
}

podman_runtime::configure() {
  # Purpose: Configure the requested state.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local podmin_home
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ -z "${podmin_home}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            podmin_home="/home/${PODMAN_USER}"
        else
            utils::log_error "Unable to determine home for ${PODMAN_USER}"
            exit 1
        fi
    fi
    podman_runtime::_ensure_containers_runtime_config /etc/containers/containers.conf root root
    podman_runtime::_ensure_containers_runtime_config "${podmin_home}/.config/containers/containers.conf" "${PODMAN_USER}" "${PODMAN_USER}"
}

podman_runtime::ensure_podmin_config_dir() {
  # Purpose: Ensure podmin config dir.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local home dir
    home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ -z "${home}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            utils::log_info "[DRY-RUN] Would ensure ${PODMAN_USER} home directory ownership"
            return 0
        fi
        utils::log_error "Unable to determine home for ${PODMAN_USER} when validating config directory ownership."
        return 1
    fi
    dir="${home}/.config"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure ${dir} exists and is owned by ${PODMAN_USER}:${PODMAN_USER}"
        return 0
    fi
    fs::ensure_dir "${dir}" 0700 "${PODMAN_USER}" "${PODMAN_USER}"
    return 0
}
