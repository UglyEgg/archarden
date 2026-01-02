# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

clear_pending_state() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would clear pending state at ${PENDING_ARGS_FILE}"
        return
    fi
    rm -f "${PENDING_ARGS_FILE}"
}

initialize_run_context() {
    local ts existing_run_id=""
    if [[ -z "${RUN_ID:-}" && ${RESUME_MODE:-0} -eq 1 ]]; then
        if [[ ! -s "${RUN_ID_FILE}" ]]; then
            log_error "Resume requested but run id missing at ${RUN_ID_FILE}; run phase 0 first."
            exit 1
        fi
        existing_run_id=$(cat "${RUN_ID_FILE}")
        RUN_ID="${existing_run_id}"
        log_info "Resuming with existing run id ${RUN_ID}"
    fi
    if [[ -z "${RUN_ID:-}" ]]; then
        ts=$(date -u '+%Y%m%d-%H%M%SZ')
        RUN_ID="${ts}"
        log_info "Generated run id ${RUN_ID} for this execution"
    fi
    BACKUP_ROOT="${BACKUP_ROOT_BASE}/${RUN_ID}"
    BACKUP_ARCHIVE="/root/archarden-backups-${RUN_ID}.tar.gz"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would record run id at ${RUN_ID_FILE} and ensure backup root ${BACKUP_ROOT}"
        return
    fi
    run_cmd "install -d -m 0700 -o root -g root \"${STATE_DIR}\""
    run_cmd "install -m 0600 /dev/null \"${RUN_ID_FILE}\""
    echo "${RUN_ID}" > "${RUN_ID_FILE}"
    backup_init_run_dir
}

run_status_capture() {
    local label="$1"; shift
    local err_file output rc err_msg
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would run: $*"
        return 0
    fi
    err_file=$(mktemp)
    rc=0
    output=$("$@" 2>"${err_file}") || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
        log_warn "${label} failed: ${err_msg:-unknown}"
    else
        while IFS= read -r line || [[ -n "${line}" ]]; do
            log_info "${label}: ${line}"
        done <<<"${output:-ok}"
    fi
    rm -f "${err_file}"
}

configure_podman_templates() {
    local dest_dir=/usr/share/vps-harden/templates/containers
    write_file_atomic /usr/share/vps-harden/README <<'EOT'
Podman templates installed by vps-harden.
EOT
    write_file_atomic "${dest_dir}/nginx-proxy-manager.container" < "${TEMPLATES_DIR}/containers/nginx-proxy-manager.container"
    write_file_atomic "${dest_dir}/podman-run-npm.sh" < "${TEMPLATES_DIR}/containers/podman-run-npm.sh"
    write_file_atomic "${dest_dir}/gotify.container" < "${TEMPLATES_DIR}/containers/gotify.container"
    write_file_atomic "${dest_dir}/uptime-kuma.container" < "${TEMPLATES_DIR}/containers/uptime-kuma.container"
    write_file_atomic "${dest_dir}/podman-run-gotify.sh" < "${TEMPLATES_DIR}/containers/podman-run-gotify.sh"
    run_cmd "chmod +x ${dest_dir}/podman-run-npm.sh"
    run_cmd "chmod +x ${dest_dir}/podman-run-gotify.sh"
}

ensure_containers_runtime_config() {
    local target="$1" owner="${2:-root}" group="${3:-root}"
    local runtime_line='runtime = "runc"'
    local tmp in_engine=0 runtime_set=0 found_engine=0
    tmp=$(mktemp)

    run_cmd "install -d -m 0755 -o ${owner} -g ${group} $(dirname "${target}")"

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

    write_file_atomic "${target}" < "${tmp}"
    rm -f "${tmp}"
    if [[ "${owner}" != "root" || "${group}" != "root" ]]; then
        run_cmd "chown ${owner}:${group} ${target}"
    fi
}

configure_podman_runtime() {
    local podmin_home
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ -z "${podmin_home}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            podmin_home="/home/${PODMAN_USER}"
        else
            log_error "Unable to determine home for ${PODMAN_USER}"
            exit 1
        fi
    fi
    ensure_containers_runtime_config /etc/containers/containers.conf root root
    ensure_containers_runtime_config "${podmin_home}/.config/containers/containers.conf" "${PODMAN_USER}" "${PODMAN_USER}"
}

ensure_podmin_config_dir() {
    local home dir
    home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ -z "${home}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            log_info "[DRY-RUN] Would ensure ${PODMAN_USER} home directory ownership"
            return 0
        fi
        log_error "Unable to determine home for ${PODMAN_USER} when validating config directory ownership."
        return 1
    fi
    dir="${home}/.config"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would ensure ${dir} exists and is owned by ${PODMAN_USER}:${PODMAN_USER}"
        return 0
    fi
    run_cmd "install -d -m 0700 -o ${PODMAN_USER} -g ${PODMAN_USER} ${dir}"
    return 0
}

subordinate_id_max_end() {
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

ensure_subordinate_ids() {
    local range_size=65536 user="${PODMAN_USER}"
    local subuid_file=/etc/subuid subgid_file=/etc/subgid
    local existing_start="" existing_size="" existing_start_gid="" existing_size_gid=""
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would ensure subordinate ID ranges for ${user} in ${subuid_file} and ${subgid_file}"
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
    max_end_subuid=$(subordinate_id_max_end "${subuid_file}")
    max_end_subgid=$(subordinate_id_max_end "${subgid_file}")
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
        run_cmd "install -m 0644 /dev/null ${subuid_file}"
    fi
    if [[ ! -f "${subgid_file}" ]]; then
        run_cmd "install -m 0644 /dev/null ${subgid_file}"
    fi

    if ! grep -q "^${user}:" "${subuid_file}" 2>/dev/null; then
        run_cmd "bash -c 'echo \"${user}:${start_range}:${size_to_use}\" >> ${subuid_file}'"
        log_info "Added subordinate UID range for ${user}: ${start_range}-${end_range}"
    fi
    if ! grep -q "^${user}:" "${subgid_file}" 2>/dev/null; then
        run_cmd "bash -c 'echo \"${user}:${start_range}:${size_to_use}\" >> ${subgid_file}'"
        log_info "Added subordinate GID range for ${user}: ${start_range}-${end_range}"
    fi
}

ensure_userns_sysctl() {
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

    run_cmd "install -d -m 0755 /etc/sysctl.d"
    write_file_atomic "${sysctl_file}" <<EOT
$(printf '%s\n' "${lines[@]}")
EOT
    run_status_capture "sysctl --system" sysctl --system
}

podmin_podman_info() {
    local runtime_dir err_file output rc=0 err_msg home_dir
    home_dir="${PODMAN_HOME:-$(eval echo "~${PODMAN_USER}")}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would run podman info as ${PODMAN_USER}"
        echo "runc"
        return 0
    fi
    ensure_podmin_user_manager || return 1
    runtime_dir="/run/user/${PODMAN_UID}"
    err_file=$(mktemp)
    output=$(HOME="${home_dir}" XDG_RUNTIME_DIR="${runtime_dir}" runuser -u "${PODMAN_USER}" -- env HOME="${home_dir}" XDG_RUNTIME_DIR="${runtime_dir}" podman info --format '{{.Host.OCIRuntime.Name}}' 2>"${err_file}")
    rc=$?
    err_msg=$(tr -d '\r' < "${err_file}")
    rm -f "${err_file}"
    output=$(echo "${output}" | tr -d '\r')
    if [[ ${rc} -ne 0 ]]; then
        log_error "podman info failed for ${PODMAN_USER}: ${err_msg:-unknown error}"
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"podman info failed: ${err_msg:-unknown error}"}
        return ${rc}
    fi
    echo "${output}"
}

ensure_rootless_podman_prereqs() {
    PODMAN_PREREQS_READY=1
    PODMAN_PREREQ_REASON=""
    if ! ensure_subordinate_ids; then
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"failed to ensure subordinate ID ranges for ${PODMAN_USER}"}
    fi
    if ! ensure_podmin_config_dir; then
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"failed to ensure ${PODMAN_USER} config directory ownership"}
    fi
    ensure_userns_sysctl
    if ! ensure_podmin_user_manager; then
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"user manager not available for ${PODMAN_USER} (no user bus)"}
        return 0
    fi
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        return 0
    fi
    if ! podmin_podman_info >/dev/null; then
        PODMAN_PREREQS_READY=0
        log_warn "Podman prerequisites not met; podman info failed for ${PODMAN_USER}."
        return 0
    fi
}

ensure_quadlet_generator() {
    local generator_dir generator_path
    generator_dir=$(systemd-path user-generators 2>/dev/null || true)
    if [[ -z "${generator_dir}" ]]; then
        generator_dir="/usr/lib/systemd/user-generators"
    fi
    local -a generator_candidates=(
        "${generator_dir%/}/podman-user-generator"
        "/usr/lib/systemd/system-generators/podman-system-generator"
    )

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would check for podman quadlet generator at: ${generator_candidates[*]}"
        return 0
    fi

    for generator_path in "${generator_candidates[@]}"; do
        if [[ -x "${generator_path}" ]]; then
            return 0
        fi
    done

    log_warn "Podman quadlet generator not found; checked: ${generator_candidates[*]}"
    log_warn "Install podman with quadlet support (podman-quadlet or podman package including quadlet) and rerun the hardener"
    return 1
}

quadlet::user_home() {
    local podmin_home
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ -z "${podmin_home}" ]]; then
        log_error "Unable to determine home for ${PODMAN_USER}"
        exit 1
    fi
    echo "${podmin_home}"
}

quadlet::systemd_dir() {
    local home
    home=$(quadlet::user_home)
    echo "${home}/.config/containers/systemd"
}

quadlet::render() {
    local template="$1" dest="$2"
    local tmp dir
    dir=$(dirname "${dest}")
    run_cmd "install -d -m 0700 -o ${PODMAN_USER} -g ${PODMAN_USER} ${dir}" >&2
    tmp=$(mktemp)
    if [[ -f "${dest}" ]]; then
        cp "${dest}" "${tmp}"
    else
        cp "${template}" "${tmp}"
    fi
    echo "${tmp}"
}

quadlet::apply_limits() {
    local dest="$1"; shift
    local tmp_out in_container=0
    declare -A desired=()
    declare -A seen=()
    local -a desired_keys=()
    local key value kv
    for kv in "$@"; do
        key=${kv%%=*}
        value=${kv#*=}
        desired["${key}"]="${value}"
        seen["${key}"]=0
        desired_keys+=("${key}")
    done
    tmp_out=$(mktemp)
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^\[.*\] ]]; then
            if [[ ${in_container} -eq 1 ]]; then
                for key in "${desired_keys[@]}"; do
                    if [[ ${seen[${key}]} -eq 0 ]]; then
                        echo "${key}=${desired[${key}]}" >>"${tmp_out}"
                    fi
                done
            fi
            in_container=0
        fi

        if [[ "${line}" == "[Container]" ]]; then
            in_container=1
            for key in "${desired_keys[@]}"; do
                seen["${key}"]=0
            done
        elif [[ ${in_container} -eq 1 ]]; then
            for key in "${desired_keys[@]}"; do
                if [[ "${line}" =~ ^${key}= ]]; then
                    case "${key}" in
                        PodmanArgs)
                            if [[ "${line}" != *"${desired[${key}]}"* ]]; then
                                line="${line} ${desired[${key}]}"
                            fi
                            ;;
                        *)
                            line="${key}=${desired[${key}]}"
                            ;;
                    esac
                    seen["${key}"]=1
                    break
                fi
            done
        fi

        echo "${line}" >>"${tmp_out}"
    done < "${dest}"

    if [[ ${in_container} -eq 1 ]]; then
        for key in "${desired_keys[@]}"; do
            if [[ ${seen[${key}]} -eq 0 ]]; then
                echo "${key}=${desired[${key}]}" >>"${tmp_out}"
            fi
        done
    fi

    write_file_atomic "${dest}" < "${tmp_out}"
    ensure_file_permissions "${dest}" 0644 "${PODMAN_USER}"
    rm -f "${tmp_out}"
}

quadlet::ensure_install_default_target() {
    local dest="$1"
    local tmp_out in_install=0 saw_install=0 saw_install_default_target=0
    tmp_out=$(mktemp)
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^\[.*\] ]]; then
            if [[ ${in_install} -eq 1 && ${saw_install_default_target} -eq 0 ]]; then
                echo "WantedBy=default.target" >>"${tmp_out}"
                saw_install_default_target=1
            fi
            in_install=0
        fi

        if [[ "${line}" == "[Install]" ]]; then
            in_install=1
            saw_install=1
        elif [[ ${in_install} -eq 1 && "${line}" =~ ^WantedBy= ]]; then
            if [[ "${line#WantedBy=}" == *"default.target"* ]]; then
                saw_install_default_target=1
            fi
        fi

        echo "${line}" >>"${tmp_out}"
    done < "${dest}"

    if [[ ${in_install} -eq 1 && ${saw_install_default_target} -eq 0 ]]; then
        echo "WantedBy=default.target" >>"${tmp_out}"
        saw_install_default_target=1
    fi

    if [[ ${saw_install} -eq 0 ]]; then
        echo >>"${tmp_out}"
        echo "[Install]" >>"${tmp_out}"
        echo "WantedBy=default.target" >>"${tmp_out}"
    elif [[ ${saw_install_default_target} -eq 0 ]]; then
        echo "WantedBy=default.target" >>"${tmp_out}"
    fi

    write_file_atomic "${dest}" < "${tmp_out}"
    ensure_file_permissions "${dest}" 0644 "${PODMAN_USER}"
    rm -f "${tmp_out}"
}

quadlet::check_duplicate_publish_ports() {
    local dest="$1"
    local line value
    declare -A seen=()
    local -a publish_lines=() duplicates=()

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would check for duplicate PublishPort entries in ${dest}"
        return
    fi

    if [[ ! -f "${dest}" ]]; then
        log_warn "PublishPort check skipped; ${dest} not found"
        return
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^PublishPort= ]]; then
            value=${line#PublishPort=}
            publish_lines+=("${value}")
            if [[ -n "${seen[${value}]+x}" ]]; then
                duplicates+=("${value}")
            fi
            seen["${value}"]=1
        fi
    done < "${dest}"

    if [[ ${#duplicates[@]} -gt 0 ]]; then
        log_error "Duplicate PublishPort entries detected in ${dest}: ${duplicates[*]}"
        log_error "PublishPort lines:"
        for value in "${publish_lines[@]}"; do
            log_error "  ${value}"
        done
        exit 1
    fi
}

quadlet::write_unit() {
    local target="$1" source_tmp="$2"
    write_file_atomic "${target}" < "${source_tmp}"
    ensure_file_permissions "${target}" 0644 "${PODMAN_USER}"
}

quadlet::restart() {
    local user="$1" service="$2"
    if [[ "${user}" == "${PODMAN_USER}" ]]; then
        if ! podmin_systemctl restart "${service}"; then
            log_warn "Failed to restart ${service} for ${user}; rootless services may not be active"
            return
        fi
        verify_quadlet_status "${service}"
        return
    fi
    run_cmd "runuser -u ${user} -- systemctl --user restart ${service}"
}

ensure_npm_quadlet() {
    local systemd_dir target tmp_out tmp_in
    systemd_dir=$(quadlet::systemd_dir)
    target="${systemd_dir}/nginx-proxy-manager.container"
    tmp_in=$(quadlet::render "${TEMPLATES_DIR}/containers/nginx-proxy-manager.container" "${target}")

    tmp_out=$(mktemp)
    local in_container=0
    local -a canonical_ports=(
        "127.0.0.1:8080:80/tcp"
        "127.0.0.1:8443:443/tcp"
        "127.0.0.1:8181:81/tcp"
    )
    local wrote_ports=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^\[.*\] ]]; then
            if [[ ${in_container} -eq 1 ]]; then
                if [[ ${wrote_ports} -eq 0 ]]; then
                    printf 'PublishPort=%s\n' "${canonical_ports[@]}" >>"${tmp_out}"
                    wrote_ports=1
                fi
            fi
            in_container=0
        fi

        if [[ ${in_container} -eq 1 ]]; then
            if [[ "${line}" =~ ^PublishPort= ]]; then
                continue
            fi

            if [[ "${line}" =~ ^Network= ]]; then
                if [[ "${line}" == "Network=host" ]]; then
                    line="Network=slirp4netns"
                fi
            fi
        fi

        echo "${line}" >>"${tmp_out}"

        if [[ "${line}" == "[Container]" ]]; then
            in_container=1
            wrote_ports=0
        fi
    done < "${tmp_in}"

    if [[ ${in_container} -eq 1 ]]; then
        if [[ ${wrote_ports} -eq 0 ]]; then
            printf 'PublishPort=%s\n' "${canonical_ports[@]}" >>"${tmp_out}"
        fi
    fi

    quadlet::write_unit "${target}" "${tmp_out}"
    quadlet::ensure_install_default_target "${target}"
    quadlet::apply_limits "${target}" "Memory=512M" "PidsLimit=512" "PodmanArgs=--memory-swap=1G"
    rm -f "${tmp_in}" "${tmp_out}"
}

ensure_gotify_quadlet() {
    local systemd_dir target tmp_in
    systemd_dir=$(quadlet::systemd_dir)
    target="${systemd_dir}/gotify.container"
    tmp_in=$(quadlet::render "${TEMPLATES_DIR}/containers/gotify.container" "${target}")

    quadlet::write_unit "${target}" "${tmp_in}"
    quadlet::ensure_install_default_target "${target}"
    quadlet::apply_limits "${target}" "Memory=128M" "PidsLimit=256"
    rm -f "${tmp_in}"
}

ensure_uptime_kuma_quadlet() {
    local systemd_dir target tmp_out tmp_in
    systemd_dir=$(quadlet::systemd_dir)
    target="${systemd_dir}/uptime-kuma.container"
    tmp_in=$(quadlet::render "${TEMPLATES_DIR}/containers/uptime-kuma.container" "${target}")

    tmp_out=$(mktemp)
    local in_container=0 saw_publish=0 saw_volume=0 saw_autoupdate=0 saw_image=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^\[.*\] ]]; then
            if [[ ${in_container} -eq 1 ]]; then
                if [[ ${saw_image} -eq 0 ]]; then
                    echo "Image=docker.io/louislam/uptime-kuma:2" >>"${tmp_out}"
                fi
                if [[ ${saw_publish} -eq 0 ]]; then
                    echo "PublishPort=3001:3001" >>"${tmp_out}"
                fi
                if [[ ${saw_volume} -eq 0 ]]; then
                    echo "Volume=/home/${PODMAN_USER}/.local/share/uptime-kuma:/app/data:Z" >>"${tmp_out}"
                fi
                if [[ ${saw_autoupdate} -eq 0 ]]; then
                    echo "AutoUpdate=registry" >>"${tmp_out}"
                fi
            fi
            in_container=0
        fi

        if [[ ${in_container} -eq 1 ]]; then
            if [[ "${line}" =~ ^Image= ]]; then
                line="Image=docker.io/louislam/uptime-kuma:2"
                saw_image=1
            fi
            if [[ "${line}" =~ ^PublishPort= ]]; then
                line="PublishPort=3001:3001"
                saw_publish=1
            fi
            if [[ "${line}" =~ ^Volume= ]]; then
                line="Volume=/home/${PODMAN_USER}/.local/share/uptime-kuma:/app/data:Z"
                saw_volume=1
            fi
            if [[ "${line}" =~ ^AutoUpdate= ]]; then
                line="AutoUpdate=registry"
                saw_autoupdate=1
            fi
        fi

        echo "${line}" >>"${tmp_out}"

        if [[ "${line}" == "[Container]" ]]; then
            in_container=1
            saw_publish=0
            saw_volume=0
            saw_autoupdate=0
            saw_image=0
        fi
    done < "${tmp_in}"

    if [[ ${in_container} -eq 1 ]]; then
        if [[ ${saw_image} -eq 0 ]]; then
            echo "Image=docker.io/louislam/uptime-kuma:2" >>"${tmp_out}"
        fi
        if [[ ${saw_publish} -eq 0 ]]; then
            echo "PublishPort=3001:3001" >>"${tmp_out}"
        fi
        if [[ ${saw_volume} -eq 0 ]]; then
            echo "Volume=/home/${PODMAN_USER}/.local/share/uptime-kuma:/app/data:Z" >>"${tmp_out}"
        fi
        if [[ ${saw_autoupdate} -eq 0 ]]; then
            echo "AutoUpdate=registry" >>"${tmp_out}"
        fi
    fi

    quadlet::write_unit "${target}" "${tmp_out}"
    quadlet::ensure_install_default_target "${target}"
    rm -f "${tmp_in}" "${tmp_out}"
}

verify_quadlet_status() {
    local service="$1"
    if ! ensure_podmin_user_manager; then
        log_warn "User manager unavailable for ${PODMAN_USER}; skipping quadlet management."
        return
    fi
    if podmin_systemctl status "${service}" --no-pager; then
        return 0
    fi
    log_warn "Status check failed for ${service}; inspecting generated units"
    run_cmd "systemctl --user --machine=${PODMAN_USER}@.host list-unit-files --no-pager | grep -E 'nginx-proxy-manager|gotify' || true"
    run_cmd "ls -la /run/user/${PODMAN_UID}/systemd/generator/ | grep -E 'nginx-proxy-manager|gotify' || true"
}

configure_rootless_quadlets() {
    local systemd_dir
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        log_warn "Skipping rootless quadlet configuration because Podman prerequisites are not satisfied: ${PODMAN_PREREQ_REASON:-unknown}."
        return
    fi
    ensure_npm_quadlet
    ensure_gotify_quadlet
    ensure_uptime_kuma_quadlet
    systemd_dir=$(quadlet::systemd_dir)
    quadlet::check_duplicate_publish_ports "${systemd_dir}/nginx-proxy-manager.container"
    if ! ensure_quadlet_generator; then
        return
    fi
    ensure_podmin_user_manager
    if ! podmin_systemctl daemon-reload; then
        log_warn "Failed to reload user systemd daemon for ${PODMAN_USER}; rootless services may not be active"
        return
    fi
    podmin_systemctl reset-failed || true
    podmin_systemctl daemon-reload || true

    local services=(
        nginx-proxy-manager.service
        gotify.service
        uptime-kuma.service
    )
    local service
    for service in "${services[@]}"; do
        if podmin_systemctl start "${service}"; then
            run_status_capture "${service} status" podmin_systemctl status "${service}" --no-pager
        else
            log_warn "Failed to start ${service}; collecting diagnostics."
            run_status_capture "${service} status" systemctl --user --machine="${PODMAN_USER}@.host" status "${service}" --no-pager || true
            run_status_capture "${service} journal" journalctl --user --machine="${PODMAN_USER}@.host" -u "${service}" -n 200 --no-pager || true
        fi
    done
}

configure_socket_proxyd() {
    local http_socket=/etc/systemd/system/archarden-http.socket
    local http_service=/etc/systemd/system/archarden-http.service
    local https_socket=/etc/systemd/system/archarden-https.socket
    local https_service=/etc/systemd/system/archarden-https.service

    backup_file "${http_socket}"
    backup_file "${http_service}"
    backup_file "${https_socket}"
    backup_file "${https_service}"

    write_file_atomic "${http_socket}" <<'EOT'
[Socket]
ListenStream=80
Accept=no

[Install]
WantedBy=sockets.target
EOT

    write_file_atomic "${http_service}" <<'EOT'
[Unit]
Requires=archarden-http.socket

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:8080
StandardInput=socket
EOT

    write_file_atomic "${https_socket}" <<'EOT'
[Socket]
ListenStream=443
Accept=no

[Install]
WantedBy=sockets.target
EOT

    write_file_atomic "${https_service}" <<'EOT'
[Unit]
Requires=archarden-https.socket

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:8443
StandardInput=socket
EOT

    run_cmd "systemctl daemon-reload"
    run_cmd "systemctl enable --now archarden-http.socket archarden-https.socket"
}

ensure_podmin_podman_socket() {
    local systemd_dir runtime_dir socket_path home_dir
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        log_warn "Skipping podman.socket setup because Podman prerequisites are not satisfied."
        return 1
    fi
    ensure_podmin_user_manager || return 1
    home_dir="${PODMAN_HOME:-$(eval echo \"~${PODMAN_USER}\")}"
    runtime_dir="/run/user/${PODMAN_UID}"
    socket_path="${runtime_dir}/podman/podman.sock"

    if ! podmin_systemctl cat podman.socket >/dev/null 2>&1; then
        systemd_dir="${home_dir}/.config/systemd/user"
        run_cmd "install -d -m 0700 -o ${PODMAN_USER} -g ${PODMAN_USER} ${systemd_dir}"
        write_file_atomic "${systemd_dir}/podman.socket" <<'EOT'
[Socket]
ListenStream=%t/podman/podman.sock
SocketMode=0660

[Install]
WantedBy=sockets.target
EOT
        write_file_atomic "${systemd_dir}/podman.service" <<'EOT'
[Service]
ExecStart=/usr/bin/podman system service --time=0 unix://%t/podman/podman.sock
KillMode=process
EOT
        ensure_file_permissions "${systemd_dir}/podman.socket" 0644 "${PODMAN_USER}"
        ensure_file_permissions "${systemd_dir}/podman.service" 0644 "${PODMAN_USER}"
    fi

    podmin_systemctl daemon-reload || true
    if ! podmin_systemctl enable --now podman.socket; then
        log_warn "Could not enable podman.socket for ${PODMAN_USER}; Podman API proxy will be skipped."
        return 1
    fi
    if [[ ! -S "${socket_path}" ]]; then
        log_warn "Podman socket not found at ${socket_path} after enabling podman.socket"
        return 1
    fi
    return 0
}

ensure_podman_api_group() {
    if getent group "${PODMAN_API_GROUP}" >/dev/null 2>&1; then
        :
    else
        run_cmd "groupadd -r ${PODMAN_API_GROUP}"
        log_info "Created system group ${PODMAN_API_GROUP} for Podman API access"
    fi
    if [[ -n "${USER_NAME}" ]]; then
        ensure_user_in_group "${USER_NAME}" "${PODMAN_API_GROUP}"
    fi
}

configure_podman_api_proxy() {
    if ! ensure_podmin_podman_socket; then
        log_warn "Skipping Podman API proxy setup because podman.socket is unavailable${PODMAN_PREREQ_REASON:+ (${PODMAN_PREREQ_REASON})}."
        return
    fi
    local podman_socket_path="/run/user/${PODMAN_UID}/podman/podman.sock"
    if [[ ! -S "${podman_socket_path}" ]]; then
        log_warn "Skipping Podman API proxy setup; expected socket missing at ${podman_socket_path}"
        return
    fi
    ensure_podman_api_group

    local proxy_socket=/etc/systemd/system/podmin-podman.socket
    local proxy_service=/etc/systemd/system/podmin-podman.service
    local podman_socket="unix:/run/user/${PODMAN_UID}/podman/podman.sock"

    backup_file "${proxy_socket}"
    backup_file "${proxy_service}"

    write_file_atomic "${proxy_socket}" <<EOT
[Unit]
Description=Proxy socket to ${PODMAN_USER} Podman API

[Socket]
ListenStream=/run/podmin-podman.sock
SocketMode=0660
SocketUser=root
SocketGroup=${PODMAN_API_GROUP}
RemoveOnStop=yes

[Install]
WantedBy=sockets.target
EOT

    write_file_atomic "${proxy_service}" <<EOT
[Unit]
Description=Proxy to ${PODMAN_USER} Podman API
Requires=podmin-podman.socket
After=podmin-podman.socket
Requires=user@${PODMAN_UID}.service
After=user@${PODMAN_UID}.service

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd ${podman_socket}
User=root
Group=root
StandardInput=socket

[Install]
WantedBy=multi-user.target
EOT

    run_cmd "systemctl daemon-reload"
    run_cmd "systemctl enable --now podmin-podman.socket"
    run_status_capture "podman.socket (podmin)" podmin_systemctl status podman.socket --no-pager
    run_status_capture "podman API proxy socket" bash -c "ss -xl | grep podmin-podman.sock || true"
    if command -v podman >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1 && [[ -n "${USER_NAME}" ]]; then
        run_status_capture "podman --remote info (as ${USER_NAME})" bash -c "sudo -u ${USER_NAME} podman --remote --url unix:///run/podmin-podman.sock info || true"
    fi
}

gotify::ensure_container_running() {
    verify_quadlet_status gotify.service
}

gotify::ensure_token() {
    local env_file=/etc/archarden/notify-gotify.env
    run_cmd "install -d -m 0700 /etc/archarden"
    ensure_file_exists "${env_file}" 0600 root root <<'EOT'
# Gotify endpoint and access token (leave blank to disable notifications)
GOTIFY_URL=
GOTIFY_TOKEN=
# Optional priority (default 5)
GOTIFY_PRIORITY=5
EOT
}

gotify::ensure_lib_dir() {
    local lib_dir=/usr/local/lib/archarden
    run_cmd "install -d -m 0750 ${lib_dir}"
}

gotify::write_root_file() {
    local path="$1" mode="$2"
    write_file_atomic "${path}"
    ensure_file_permissions "${path}" "${mode}" root
}

gotify::install_notify_script() {
    local lib_dir=/usr/local/lib/archarden
    gotify::ensure_lib_dir
    gotify::write_root_file "${lib_dir}/gotify_send.sh" 0750 <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

env_file="/etc/archarden/notify-gotify.env"
if [[ -f "${env_file}" ]]; then
  # shellcheck disable=SC1090
  source "${env_file}"
fi

if [[ -z "${GOTIFY_URL:-}" || -z "${GOTIFY_TOKEN:-}" ]]; then
  echo "Gotify not configured; skipping notification" >&2
  exit 0
fi

if [[ $# -lt 2 ]]; then
  echo "Usage: ${0} <title> <message>" >&2
  exit 1
fi

title="$1"
message="$2"
priority="${GOTIFY_PRIORITY:-5}"

if [[ ${#message} -gt 3500 ]]; then
  message="${message:0:3500}"
fi

if ! curl -fsS -X POST "${GOTIFY_URL%/}/message?token=${GOTIFY_TOKEN}" \
  -F "title=${title}" \
  -F "message=${message}" \
  -F "priority=${priority}" >/dev/null; then
  echo "Failed to send Gotify notification" >&2
fi
EOT
}

gotify::install_units() {
    local lib_dir=/usr/local/lib/archarden
    local os_report_service=/etc/systemd/system/archarden-os-report.service
    local os_report_timer=/etc/systemd/system/archarden-os-report.timer
    local container_scan_service=/etc/systemd/system/archarden-container-scan.service
    local container_scan_timer=/etc/systemd/system/archarden-container-scan.timer

    gotify::ensure_lib_dir
    gotify::write_root_file "${lib_dir}/os_update_report.sh" 0750 <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

notify_bin="/usr/local/lib/archarden/gotify_send.sh"
updates_output=""
audit_output=""

if command -v checkupdates >/dev/null 2>&1; then
  updates_output=$(checkupdates 2>/dev/null || true)
else
  echo "checkupdates not available; skipping pacman update check" >&2
fi

if command -v arch-audit >/dev/null 2>&1; then
  audit_output=$(arch-audit 2>/dev/null || true)
else
  echo "arch-audit not available; skipping advisory check" >&2
fi

if [[ -z "${updates_output}" && -z "${audit_output}" ]]; then
  exit 0
fi

message="PACMAN UPDATES"
if [[ -n "${updates_output}" ]]; then
  message+="
${updates_output}"
else
  message+="
None"
fi

message+="

ARCH-AUDIT"
if [[ -n "${audit_output}" ]]; then
  message+="
${audit_output}"
else
  message+="
None"
fi

"${notify_bin}" "Arch updates and advisories" "${message}"
EOT

    gotify::write_root_file "${lib_dir}/container_update_scan.sh" 0750 <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

notify_bin="/usr/local/lib/archarden/gotify_send.sh"
auto_update_output=""
ps_output=""
updates_rc=0

if command -v podman >/dev/null 2>&1; then
  auto_update_output=$(runuser -u podmin -- podman auto-update --dry-run 2>&1) || updates_rc=$?
  ps_output=$(runuser -u podmin -- podman ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>&1 || true)
else
  updates_rc=1
  auto_update_output="podman not available"
fi

trimmed_updates=$(echo "${auto_update_output}" | sed '/^[[:space:]]*$/d')

if [[ ${updates_rc} -ne 0 ]]; then
  message="Podman auto-update --dry-run failed:
${auto_update_output}"
  if [[ -n "${ps_output}" ]]; then
    message+="

Running containers:
${ps_output}"
  fi
  "${notify_bin}" "Container update scan error" "${message}"
  exit 0
fi

if [[ -z "${trimmed_updates}" ]] || [[ "${trimmed_updates,,}" =~ no[[:space:]]+.*update ]]; then
  exit 0
fi

message="Podman auto-update --dry-run reported updates:
${trimmed_updates}"

if [[ -n "${ps_output}" ]]; then
  message+="

Running containers:
${ps_output}"
fi

"${notify_bin}" "Container updates available" "${message}"
EOT

    gotify::write_root_file "${os_report_service}" 0644 <<'EOT'
[Unit]
Description=Archarden daily OS update and advisory report
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/archarden/os_update_report.sh
EOT

    gotify::write_root_file "${os_report_timer}" 0644 <<'EOT'
[Unit]
Description=Run archarden OS update report daily

[Timer]
OnCalendar=*-*-* 03:15:00
Persistent=true

[Install]
WantedBy=timers.target
EOT

    gotify::write_root_file "${container_scan_service}" 0644 <<'EOT'
[Unit]
Description=Archarden weekly container update scan
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/archarden/container_update_scan.sh
EOT

    gotify::write_root_file "${container_scan_timer}" 0644 <<'EOT'
[Unit]
Description=Run archarden container update scan weekly

[Timer]
OnCalendar=Sun 04:20:00
Persistent=true

[Install]
WantedBy=timers.target
EOT
}

gotify::verify() {
    run_cmd "systemctl daemon-reload"
    run_cmd "systemctl enable --now archarden-os-report.timer"
    run_cmd "systemctl enable --now archarden-container-scan.timer"
}

configure_gotify_notifications() {
    gotify::ensure_container_running
    gotify::ensure_token
    gotify::install_notify_script
    gotify::install_units
    gotify::verify
}

discover_public_ipv4() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") print $(i+1)}' | head -n1)
    if [[ -z "${ip}" ]]; then
        ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {sub("/.*","",$2); print $2}' | head -n1)
    fi
    echo "${ip}"
}

load_wireguard_config() {
    local cfg="${CONFIG_DIR}/wireguard.conf" entry name ip
    if [[ ! -f "${cfg}" ]]; then
        log_error "WireGuard config file not found at ${cfg}"
        exit 1
    fi

    WG_PEERS=()
    # shellcheck disable=SC1090
    source "${cfg}"

    if [[ -z "${WG_INTERFACE_ADDRESS:-}" || -z "${WG_LISTEN_PORT:-}" || -z "${WG_DNS:-}" ]]; then
        log_error "WG_INTERFACE_ADDRESS, WG_LISTEN_PORT, and WG_DNS must be set in ${cfg}"
        exit 1
    fi

    WIREGUARD_SERVER_IP="${WG_INTERFACE_ADDRESS%%/*}"
    WIREGUARD_SERVER_ALLOWED_IP="${WIREGUARD_SERVER_IP}/32"
    WIREGUARD_PEER_NAMES=()
    WIREGUARD_PEER_IPS=()

    if [[ ${#WG_PEERS[@]} -eq 0 ]]; then
        log_error "WG_PEERS must include at least one entry in ${cfg} (format: name:address)"
        exit 1
    fi

    for entry in "${WG_PEERS[@]}"; do
        IFS=":" read -r name ip <<<"${entry}"
        if [[ -z "${name}" || -z "${ip}" ]]; then
            log_error "Invalid WireGuard peer entry '${entry}' in ${cfg}; expected name:address"
            exit 1
        fi
        WIREGUARD_PEER_NAMES+=("${name}")
        WIREGUARD_PEER_IPS+=("${ip}")
    done

    WIREGUARD_CONFIG_LOADED=1
}

ensure_wireguard_config_loaded() {
    if [[ ${WIREGUARD_CONFIG_LOADED} -eq 0 ]]; then
        load_wireguard_config
    fi
}

ensure_wireguard_keypair() {
    local name="$1" key_path="$2" pub_path="$3"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would ensure WireGuard keypair for ${name} at ${key_path}"
        return
    fi
    run_cmd "install -d -m 0700 /etc/wireguard/keys"
    if [[ ! -f "${key_path}" ]]; then
        run_cmd "umask 077 && wg genkey > ${key_path}"
    fi
    if [[ ! -f "${pub_path}" ]]; then
        run_cmd "umask 077 && wg pubkey < ${key_path} > ${pub_path}"
    fi
    run_cmd "chmod 0600 ${key_path} ${pub_path}"
}

read_wireguard_key() {
    local path="$1" fallback="$2"
    if [[ -f "${path}" ]]; then
        tr -d '\n' < "${path}"
    else
        echo "${fallback}"
    fi
}

append_wireguard_peer() {
    local tmp_file="$1" name="$2" pub_key="$3" allowed_ip="$4"
    if grep -q "PublicKey = ${pub_key}" "${tmp_file}"; then
        return
    fi
    {
        echo
        echo "[Peer]"
        echo "# ${name}"
        echo "PublicKey = ${pub_key}"
        echo "AllowedIPs = ${allowed_ip}"
        echo "PersistentKeepalive = 25"
    } >> "${tmp_file}"
}

ensure_wireguard_config() {
    ensure_wireguard_config_loaded
    local server_priv server_pub tmp wg_conf=/etc/wireguard/wg0.conf
    local -a peer_pub_keys=()
    if [[ ${DRY_RUN} -eq 1 ]]; then
        server_priv="DRY_RUN_SERVER_KEY"
        server_pub="DRY_RUN_SERVER_PUB"
        for name in "${WIREGUARD_PEER_NAMES[@]}"; do
            peer_pub_keys+=("DRY_RUN_${name^^}_PUB")
        done
    else
        ensure_wireguard_keypair "server" /etc/wireguard/keys/server.key /etc/wireguard/keys/server.pub
        server_priv=$(read_wireguard_key /etc/wireguard/keys/server.key "")
        server_pub=$(read_wireguard_key /etc/wireguard/keys/server.pub "")
        local idx=0
        for name in "${WIREGUARD_PEER_NAMES[@]}"; do
            ensure_wireguard_keypair "${name}" "/etc/wireguard/keys/${name}.key" "/etc/wireguard/keys/${name}.pub"
            peer_pub_keys[idx]=$(read_wireguard_key "/etc/wireguard/keys/${name}.pub" "")
            ((idx += 1))
        done
        run_cmd "install -d -m 0700 /root/wireguard/clients"
    fi

    tmp=$(mktemp)
    if [[ ! -f "${wg_conf}" ]]; then
        cat <<EOT > "${tmp}"
[Interface]
Address = ${WG_INTERFACE_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = ${server_priv}
EOT
    else
        local in_interface=0 saw_address=0 saw_listen=0 saw_private=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^\[.*\] ]]; then
                if [[ ${in_interface} -eq 1 ]]; then
                    if [[ ${saw_address} -eq 0 ]]; then
                        echo "Address = ${WG_INTERFACE_ADDRESS}" >> "${tmp}"
                    fi
                    if [[ ${saw_listen} -eq 0 ]]; then
                        echo "ListenPort = ${WG_LISTEN_PORT}" >> "${tmp}"
                    fi
                    if [[ ${saw_private} -eq 0 ]]; then
                        echo "PrivateKey = ${server_priv}" >> "${tmp}"
                    fi
                fi
                in_interface=0
            fi

            if [[ "${line}" == "[Interface]" ]]; then
                in_interface=1
                saw_address=0
                saw_listen=0
                saw_private=0
            elif [[ ${in_interface} -eq 1 ]]; then
                if [[ "${line}" =~ ^Address[[:space:]]*= ]]; then
                    line="Address = ${WG_INTERFACE_ADDRESS}"
                    saw_address=1
                elif [[ "${line}" =~ ^ListenPort[[:space:]]*= ]]; then
                    line="ListenPort = ${WG_LISTEN_PORT}"
                    saw_listen=1
                elif [[ "${line}" =~ ^PrivateKey[[:space:]]*= ]]; then
                    line="PrivateKey = ${server_priv}"
                    saw_private=1
                fi
            fi

            echo "${line}" >> "${tmp}"
        done < "${wg_conf}"

        if [[ ${in_interface} -eq 1 ]]; then
            if [[ ${saw_address} -eq 0 ]]; then
                echo "Address = ${WG_INTERFACE_ADDRESS}" >> "${tmp}"
            fi
            if [[ ${saw_listen} -eq 0 ]]; then
                echo "ListenPort = ${WG_LISTEN_PORT}" >> "${tmp}"
            fi
            if [[ ${saw_private} -eq 0 ]]; then
                echo "PrivateKey = ${server_priv}" >> "${tmp}"
            fi
        fi
    fi

    local i
    for i in "${!WIREGUARD_PEER_NAMES[@]}"; do
        append_wireguard_peer "${tmp}" "${WIREGUARD_PEER_NAMES[i]}" "${peer_pub_keys[i]}" "${WIREGUARD_PEER_IPS[i]}"
    done

    write_file_atomic "${wg_conf}" < "${tmp}"
    rm -f "${tmp}"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        run_cmd "chmod 0600 ${wg_conf}"
        run_cmd "chown root:root ${wg_conf}"
    fi
}

ensure_wireguard_client_config() {
    local name="${1-}" ip_addr="${2-}" server_pub="${3-}" endpoint="${4-}"
    if [[ -z "${name}" || -z "${ip_addr}" || -z "${server_pub}" || -z "${endpoint}" ]]; then
        log_error "ensure_wireguard_client_config requires name, ip_addr, server_pub, and endpoint"
        exit 1
    fi

    local key_path="/etc/wireguard/keys/${name}.key" pub_path="/etc/wireguard/keys/${name}.pub" client_conf="/root/wireguard/clients/${name}.conf"
    local priv_key pub_key tmp
    if [[ ${DRY_RUN} -eq 1 ]]; then
        priv_key="DRY_RUN_${name^^}_KEY"
        pub_key="DRY_RUN_${name^^}_PUB"
    else
        ensure_wireguard_keypair "${name}" "${key_path}" "${pub_path}"
        priv_key=$(read_wireguard_key "${key_path}" "")
        pub_key=$(read_wireguard_key "${pub_path}" "")
    fi

    tmp=$(mktemp)
    cat <<EOT > "${tmp}"
[Interface]
Address = ${ip_addr}
PrivateKey = ${priv_key}
DNS = ${WG_DNS}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}
AllowedIPs = ${WIREGUARD_SERVER_ALLOWED_IP}
PersistentKeepalive = 25
EOT

    write_file_atomic "${client_conf}" < "${tmp}"
    rm -f "${tmp}"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        run_cmd "chmod 0600 ${client_conf}"
        run_cmd "chown root:root ${client_conf}"
    fi
}

configure_wireguard() {
    ensure_wireguard_config_loaded
    local server_pub endpoint_ip endpoint_host="YOUR_SERVER_IP" endpoint

    ensure_wireguard_config
    server_pub=$(read_wireguard_key /etc/wireguard/keys/server.pub "DRY_RUN_SERVER_PUB")
    endpoint_ip=$(discover_public_ipv4)
    if [[ -n "${endpoint_ip}" ]]; then
        endpoint_host="${endpoint_ip}"
    else
        log_warn "Could not detect public IPv4 address; using placeholder in WireGuard client configs"
    fi
    endpoint="${endpoint_host}:${WG_LISTEN_PORT}"

    local i
    for i in "${!WIREGUARD_PEER_NAMES[@]}"; do
        ensure_wireguard_client_config "${WIREGUARD_PEER_NAMES[i]}" "${WIREGUARD_PEER_IPS[i]}" "${server_pub}" "${endpoint}"
    done

    if [[ ${DRY_RUN} -eq 0 ]]; then
        run_cmd "systemctl enable --now wg-quick@wg0.service"
    else
        log_info "[DRY-RUN] Would enable and start wg-quick@wg0.service"
    fi
    run_status_capture "wg show wg0" wg show wg0
    run_status_capture "systemctl is-active wg-quick@wg0" systemctl is-active wg-quick@wg0.service
    log_info "WireGuard client configs available under /root/wireguard/clients"
}

ensure_podmin_user() {
    local expected_home="/home/${PODMAN_USER}" current_home current_shell
    if id -u "${PODMAN_USER}" >/dev/null 2>&1; then
        log_info "Podman runtime user ${PODMAN_USER} already exists"
        current_home=$(getent passwd "${PODMAN_USER}" | cut -d: -f6)
        current_shell=$(getent passwd "${PODMAN_USER}" | cut -d: -f7)
        if [[ "${current_home}" != "${expected_home}" ]]; then
            run_cmd "usermod -d ${expected_home} -m ${PODMAN_USER}"
        fi
        if [[ "${current_shell}" != "/usr/bin/nologin" ]]; then
            run_cmd "usermod -s /usr/bin/nologin ${PODMAN_USER}"
        fi
    else
        run_cmd "useradd -m -d ${expected_home} -s /usr/bin/nologin ${PODMAN_USER}"
        log_info "Created podman runtime user ${PODMAN_USER} with nologin shell"
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would lock password for ${PODMAN_USER}"
    else
        run_cmd "passwd -l ${PODMAN_USER}"
    fi
    if getent group ssh >/dev/null 2>&1; then
        run_cmd "gpasswd -d ${PODMAN_USER} ssh >/dev/null 2>&1 || true"
    fi
    if getent group wheel >/dev/null 2>&1; then
        run_cmd "gpasswd -d ${PODMAN_USER} wheel >/dev/null 2>&1 || true"
    fi
    run_cmd "install -d -m 0750 -o ${PODMAN_USER} -g ${PODMAN_USER} ${expected_home}"
    PODMAN_HOME=$(getent passwd "${PODMAN_USER}" | cut -d: -f6)
    if [[ -z "${PODMAN_HOME}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            PODMAN_HOME="${expected_home}"
        else
            log_error "Unable to determine home for ${PODMAN_USER}"
            exit 1
        fi
    fi
    if ! loginctl enable-linger "${PODMAN_USER}" >/dev/null 2>&1; then
        log_warn "Could not enable linger for ${PODMAN_USER}; rootless services may not restart after reboot"
    fi
}

ensure_grub_defaults_saved() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would ensure /etc/default/grub has GRUB_DEFAULT=saved and GRUB_SAVEDEFAULT=true"
        return
    fi
    if [[ ! -f /etc/default/grub ]]; then
        log_error "/etc/default/grub not found; cannot set GRUB_DEFAULT/GRUB_SAVEDEFAULT."
        exit 1
    fi
    backup_file /etc/default/grub
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
        run_cmd "sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub"
    else
        run_cmd "echo 'GRUB_DEFAULT=saved' >> /etc/default/grub"
    fi
    if grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
        run_cmd "sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub"
    else
        run_cmd "echo 'GRUB_SAVEDEFAULT=true' >> /etc/default/grub"
    fi
}

ensure_lts_kernel_and_reboot_gate() {
    if ! command -v grub-mkconfig >/dev/null 2>&1; then
        log_error "grub-mkconfig not found; unable to set linux-lts as default."
        exit 1
    fi
    if ! command -v grub-set-default >/dev/null 2>&1; then
        log_error "grub-set-default not found; unable to set linux-lts as default."
        exit 1
    fi
    if ! command -v grub-editenv >/dev/null 2>&1; then
        log_error "grub-editenv not found; unable to verify default boot entry."
        exit 1
    fi

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would fully upgrade, install linux-lts, regenerate GRUB, set default to '${GRUB_LTS_ENTRY}', verify grub-editenv, and require reboot before hardening."
        return
    fi

    local current_kernel saved_entry
    current_kernel=$(uname -r)
    saved_entry=$(grub-editenv list 2>/dev/null | awk -F= '/^saved_entry=/{print $2}' || true)

    if [[ "${current_kernel}" == *-lts ]] && [[ "${saved_entry}" == "${GRUB_LTS_ENTRY}" ]]; then
        log_info "System already booted into linux-lts with GRUB default set; continuing with hardening."
        return
    fi

    log_info "Pre-hardening: updating system and preparing linux-lts default boot entry."
    if ! {
        run_cmd "pacman -Syu --noconfirm"
        run_cmd "pacman -S --needed --noconfirm linux-lts"
        ensure_grub_defaults_saved
        run_cmd "grub-mkconfig -o ${GRUB_CONFIG_PATH}"
        run_cmd "grub-set-default \"${GRUB_LTS_ENTRY}\""
    }; then
        log_error "$(red "linux-lts installation failed; please review ${LOG_FILE}")"
        exit 1
    fi

    saved_entry=$(grub-editenv list 2>/dev/null | awk -F= '/^saved_entry=/{print $2}' || true)
    if [[ "${saved_entry}" != "${GRUB_LTS_ENTRY}" ]]; then
        log_error "Expected GRUB saved_entry '${GRUB_LTS_ENTRY}', but grub-editenv reported '${saved_entry:-<unset>}'"
        exit 1
    fi

    record_pending_args "${INVOCATION_ARGS[@]}"
    write_continue_service
    local resume_cmd="${INSTALL_BIN} --resume $(cat ${PENDING_ARGS_FILE})"
    log_warn "$(yellow "Reboot required: linux-lts installed and set as default. Rebooting will auto-resume hardening via systemd.")"
    log_info "Manual resume command: ${resume_cmd}"
    log_info "$(green "LTS kernel installed. Rebooting in 5 seconds...")"
    sleep 5
    run_cmd "reboot"
}

switch_to_phase1_logging() {
    if [[ -z "${RUN_ID:-}" ]]; then
        if [[ ! -s "${RUN_ID_FILE}" ]]; then
            log_error "Resume requested but run id missing at ${RUN_ID_FILE}; run phase 0 first."
            exit 1
        fi
        RUN_ID=$(cat "${RUN_ID_FILE}")
        BACKUP_ROOT="${BACKUP_ROOT_BASE}/${RUN_ID}"
        BACKUP_ARCHIVE="/root/archarden-backups-${RUN_ID}.tar.gz"
        log_info "Loaded run id ${RUN_ID} for phase 1 resume"
    fi
    CURRENT_PHASE="phase1"
    LOG_FILE="${PHASE1_LOG}"
    export LOG_FILE
    log_info "==== Starting Phase 1 actions (logging to ${LOG_FILE}) ===="
}

run_as_user() {
    local user="$1"; shift
    local cmd="$*"
    local uid runtime_dir
    uid=$(id -u "${user}")
    runtime_dir="/run/user/${uid}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] (as ${user}) ${cmd}"
        return 0
    fi
    if [[ ! -d "${runtime_dir}" ]]; then
        log_warn "Runtime directory ${runtime_dir} missing for ${user}; ensure logind is managing the session."
    fi
    log_info "Running as ${user}: ${cmd}"
    set +e
    HOME=$(eval echo "~${user}") XDG_RUNTIME_DIR="${runtime_dir}" runuser -l "${user}" -c "${cmd}"
    local rc=$?
    set -e
    return ${rc}
}

ensure_podmin_user_manager() {
    local runtime_dir err_file err_msg
    if [[ ${ENSURED_PODMIN_MANAGER} -eq 1 ]]; then
        return 0
    fi
    if [[ -n "${PODMAN_UID}" ]]; then
        runtime_dir="/run/user/${PODMAN_UID}"
    else
        PODMAN_UID=$(id -u "${PODMAN_USER}")
        runtime_dir="/run/user/${PODMAN_UID}"
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Ensuring user manager for ${PODMAN_USER} (uid ${PODMAN_UID})"
        return 0
    fi
    if ! loginctl enable-linger "${PODMAN_USER}" >/dev/null 2>&1; then
        log_warn "Could not enable linger for ${PODMAN_USER}; rootless services may not persist across reboots"
    fi
    err_file=$(mktemp)
    if ! systemctl start "user@${PODMAN_UID}.service" >/dev/null 2>"${err_file}"; then
        err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
        if [[ -n "${err_msg}" ]]; then
            log_warn "Could not start user@${PODMAN_UID}.service for ${PODMAN_USER}: ${err_msg}"
        fi
    fi
    if [[ ! -S "${runtime_dir}/bus" ]]; then
        log_error "DBus session bus missing at ${runtime_dir}/bus for ${PODMAN_USER}; logind must manage the user session. Skipping Podman setup."
        PODMAN_PREREQS_READY=0
        rm -f "${err_file}"
        return 1
    fi
    rm -f "${err_file}"
    ENSURED_PODMIN_MANAGER=1
}

podmin_systemctl() {
    local uid runtime_dir err_file err_msg
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] (as ${PODMAN_USER}) systemctl --user --machine=${PODMAN_USER}@.host $*"
        return 0
    fi
    ensure_podmin_user_manager
    uid="${PODMAN_UID}"
    runtime_dir="/run/user/${uid}"

    err_file=$(mktemp)
    if systemctl --user --machine="${PODMAN_USER}@.host" "$@" >/dev/null 2>"${err_file}"; then
        rm -f "${err_file}"
        return 0
    fi
    err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
    rm -f "${err_file}"
    log_warn "podmin systemctl (machine) failed: ${err_msg:-unknown}; retrying with runtime dir bus"

    if [[ ! -S "${runtime_dir}/bus" ]]; then
        err_file=$(mktemp)
        if ! systemctl start "user@${uid}.service" >/dev/null 2>"${err_file}"; then
            err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
            if [[ -n "${err_msg}" ]]; then
                log_warn "Could not ensure user@${uid}.service for ${PODMAN_USER}: ${err_msg}"
            fi
        fi
        rm -f "${err_file}"
    fi

    err_file=$(mktemp)
    if XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" runuser -u "${PODMAN_USER}" -- systemctl --user "$@" >/dev/null 2>"${err_file}"; then
        rm -f "${err_file}"
        return 0
    fi
    err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
    rm -f "${err_file}"
    log_warn "podmin systemctl (fallback) failed: ${err_msg:-unknown}; rootless services may not be active"
    return 1
}

final_summary() {
    log_info "==== ✅ Hardening completed ===="
    local summary output_dir
    summary=$(
        cat <<EOF
✅ Hardening completed successfully.
$( (( ENABLE_FIREWALL )) && echo "🔒 Firewall: configured (ufw)" || echo "🔓 Firewall: skipped")
$( (( ENABLE_FAIL2BAN )) && echo "🛡️ Fail2ban: enabled" || echo "🛡️ Fail2ban: skipped")
🐧 Kernel: $(uname -r)
📦 Packages updated and installed.
🧰 Templates installed to /usr/share/vps-harden/templates/containers
🔑 WireGuard client configs: /root/wireguard/clients/*.conf
📜 Log: ${LOG_FILE}
EOF
    )
    if [[ -n "${USER_NAME}" ]] && id -u "${USER_NAME}" >/dev/null 2>&1; then
        output_dir="/home/${USER_NAME}"
    else
        output_dir="/root"
    fi
    FINAL_LOG_FILE="${output_dir}/vps-harden.log"
    echo "${summary}" > "${FINAL_LOG_FILE}"
    if [[ -n "${USER_NAME}" ]] && id -u "${USER_NAME}" >/dev/null 2>&1; then
        chown "${USER_NAME}:${USER_NAME}" "${FINAL_LOG_FILE}"
    fi
    log_info "Summary written to ${FINAL_LOG_FILE}"
}

write_user_readme() {
    local target_user="${USER_NAME}" target_home readme_path alt_readme marker dest vpn_ip gotify_port npm_port=81 kuma_port=3001 wg_client_dir="/root/wireguard/clients"
    marker="${README_MARKER}"
    gotify_port=${GOTIFY_PORT}
    vpn_ip="${WIREGUARD_SERVER_IP:-${WG_INTERFACE_ADDRESS%%/*}}"
    if [[ -z "${vpn_ip}" ]]; then
        vpn_ip="10.66.66.1"
    fi
    if [[ -z "${target_user}" ]]; then
        log_warn "No target user specified; skipping README generation"
        return
    fi
    target_home=$(getent passwd "${target_user}" | cut -d: -f6)
    if [[ -z "${target_home}" ]]; then
        log_error "Unable to determine home directory for ${target_user}"
        return
    fi
    readme_path="${target_home}/README.md"
    alt_readme="${target_home}/README.archarden.md"
    dest="${readme_path}"
    if [[ -f "${readme_path}" ]] && ! grep -qF "${marker}" "${readme_path}"; then
        dest="${alt_readme}"
    elif [[ -f "${alt_readme}" ]] && grep -qF "${marker}" "${alt_readme}"; then
        dest="${alt_readme}"
    fi

    local content
    content=$(cat <<EOF
${marker}
# Archarden: next steps after reboot

## 1. Establish WireGuard VPN connection
- Server VPN IP: ${vpn_ip}
- Client configs to retrieve:
  - ${wg_client_dir}/laptop.conf
  - ${wg_client_dir}/phone.conf
- Copy a client config securely (replace <server> with your hostname or IP):
  - scp -P ${SSH_PORT} root@<server>:${wg_client_dir}/laptop.conf .
  - (or: sudo cat ${wg_client_dir}/laptop.conf > laptop.conf)
- Bring the tunnel up on the client:
  - Linux: wg-quick up ./laptop.conf
  - Mobile: import the config into the WireGuard app
- Verify on the server:
  - sudo wg show wg0
  - Expected: peer handshakes updating for connected clients.

## 2. Bind admin ports to the VPN interface only
- Policy: admin services stay off the public internet; they should only listen on wg0.
- Apply/confirm UFW rules:
  - sudo ufw allow in on wg0 to any port ${npm_port} proto tcp comment 'NPM Admin (VPN)'
  - sudo ufw allow in on wg0 to any port ${kuma_port} proto tcp comment 'Uptime Kuma (VPN)'
  - sudo ufw allow in on wg0 to any port ${gotify_port} proto tcp comment 'Gotify (VPN)'
- Verify:
  - sudo ufw status verbose
  - ss -lntup | grep -E ':(81|3001|${gotify_port})\\b' || true
  - (Optional) External scans should NOT show these ports.

## 3. Connect to admin services (after VPN is up)
- Use a browser (or SSH tunnel if preferred) after VPN is up to configure each service:
  - NPM Admin: http://${vpn_ip}:${npm_port}
  - Uptime Kuma: http://${vpn_ip}:${kuma_port}
  - Gotify: http://${vpn_ip}:${gotify_port}

## 4. OPTIONAL (after verifying VPN works)
- Restrict SSH to the VPN only (keep console/rescue for break-glass access):
  - sudo ufw delete limit ${SSH_PORT}/tcp || sudo ufw delete allow ${SSH_PORT}/tcp
  - sudo ufw allow in on wg0 to any port ${SSH_PORT} proto tcp comment 'SSH (VPN only)'
- Restrict admin ports to wg0 if not already done:
  - sudo ufw allow in on wg0 to any port ${npm_port} proto tcp comment 'NPM Admin (VPN)'
  - sudo ufw allow in on wg0 to any port ${kuma_port} proto tcp comment 'Uptime Kuma (VPN)'
  - sudo ufw allow in on wg0 to any port ${gotify_port} proto tcp comment 'Gotify (VPN)'
- Post-VPN validation:
  - Confirm no public-facing allow/limit rules remain for SSH or admin ports.
  - Re-scan from outside the VPN to verify only expected services are exposed.
EOF
)
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would write ${dest} for ${target_user}"
        echo "${content}" | sed 's/^/    /' >&2
        return
    fi
    write_file_atomic "${dest}" <<< "${content}"
    run_cmd "chown ${target_user}:${target_user} \"${dest}\""
    run_cmd "chmod 0644 \"${dest}\""
    log_info "User README written to ${dest}"
}

archive_backups() {
    ensure_backup_root
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would archive backups from ${BACKUP_ROOT} to ${BACKUP_ARCHIVE}"
        return
    fi
    if [[ ! -d "${BACKUP_ROOT}" ]]; then
        run_cmd "install -d -m 0700 -o root -g root \"${BACKUP_ROOT}\""
    fi
    if [[ -f "${BACKUP_ARCHIVE}" ]]; then
        run_cmd "rm -f \"${BACKUP_ARCHIVE}\""
    fi
    run_cmd "umask 077 && tar -C /root -czf \"${BACKUP_ARCHIVE}\" \"archarden-backups/${RUN_ID}\""
    run_cmd "chown root:root \"${BACKUP_ARCHIVE}\""
    run_cmd "chmod 0600 \"${BACKUP_ARCHIVE}\""
    log_info "Backups archived at ${BACKUP_ARCHIVE}"
    log_info "Backup directory retained at ${BACKUP_ROOT}"
}

trigger_final_reboot() {
    log_info "==== Phase 1 completed; system will reboot in 5 seconds to finalize services and quadlets ===="
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would reboot now to complete Phase 1"
        return
    fi
    sleep 5
    run_cmd "reboot"
}

install_packages() {
    local pkgs=()
    while IFS= read -r pkg; do
        pkgs+=("${pkg}")
    done < <(read_packages_from_file "${CONFIG_DIR}/packages.list")

    if [[ ${ENABLE_AUDITD} -eq 1 ]]; then
        while IFS= read -r pkg; do
            pkgs+=("${pkg}")
        done < <(read_packages_from_file "${CONFIG_DIR}/packages.auditd.list" 1)
    fi

    while IFS= read -r pkg; do
        pkgs+=("${pkg}")
    done < <(read_packages_from_file "${CONFIG_DIR}/packages.custom.list" 1)

    apply_package_replacements pkgs

    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log_warn "No packages defined for installation; skipping package installation"
        return
    fi

    log_info "Updating system and installing packages: ${pkgs[*]}"
    run_cmd "pacman -Syu --noconfirm ${pkgs[*]}"
}

install_self() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would install archarden to ${INSTALL_PREFIX} and symlink to ${INSTALL_BIN}"
        return
    fi
    if [[ "${SCRIPT_DIR}" != "${INSTALL_PREFIX}" ]]; then
        mkdir -p "${INSTALL_PREFIX}"
        run_cmd "cp -a ${SCRIPT_DIR}/. ${INSTALL_PREFIX}/"
    fi
    run_cmd "install -m 0755 ${INSTALL_PREFIX}/harden ${INSTALL_BIN}"
}

next_available_system_gid() {
    local gid used
    mapfile -t used < <(getent group | awk -F: '{print $3}')
    for gid in $(seq 999 -1 100); do
        if ! printf '%s\n' "${used[@]}" | grep -qx "${gid}"; then
            echo "${gid}"
            return 0
        fi
    done
    return 1
}



preflight() {
    require_root
    if [[ -z "${SYSTEM_HOSTNAME}" ]]; then
        log_error "--hostname is required."
        exit 1
    fi
    if [[ -z "${USER_NAME}" ]]; then
        log_error "--user is required."
        exit 1
    fi
    if [[ -z "${PUBKEY_FILE}" && -z "${PUBKEY_VALUE}" ]]; then
        log_error "Either --pubkey-file or --pubkey is required."
        exit 1
    fi
    if ! grep -qi 'arch' /etc/os-release; then
        log_error "This tool is intended for Arch Linux systems."
        exit 1
    fi
    if ! [[ ${SSH_PORT} =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        log_error "Invalid --ssh-port '${SSH_PORT}'. Must be 1-65535."
        exit 1
    fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        SSH_CONNECTION_INFO=${SSH_CONNECTION}
        log_info "Running under SSH from ${SSH_CONNECTION_INFO}"
    else
        log_warn "Not running under SSH; lockout protections limited."
    fi
}

read_packages_from_file() {
    local file="$1" optional="${2:-0}"
    if [[ ! -f "${file}" ]]; then
        if [[ "${optional}" -eq 1 ]]; then
            log_warn "Optional package list not found: ${file}; skipping"
            return
        fi
        log_error "Required package list not found: ${file}"
        exit 1
    fi

    grep -Ev '^[[:space:]]*(#|$)' "${file}"
}

apply_package_replacements() {
    local packages_var="$1"
    local -n packages_ref=${packages_var}
    local replacements_file="${CONFIG_DIR}/packages.replacements.list"
    local -a replacements=()

    while IFS= read -r line; do
        replacements+=("${line}")
    done < <(read_packages_from_file "${replacements_file}" 1)

    if [[ ${#replacements[@]} -eq 0 ]]; then
        return
    fi

    local entry current replacement
    for entry in "${replacements[@]}"; do
        read -r current replacement <<<"${entry}"
        if [[ -z "${current}" || -z "${replacement}" ]]; then
            log_warn "Skipping malformed replacement entry: ${entry}"
            continue
        fi
        if ! package_requested "${replacement}" "${packages_var}"; then
            continue
        fi
        if package_installed "${current}"; then
            replace_package "${current}" "${replacement}"
        fi
    done
}

package_requested() {
    local target="$1"
    local -n packages_ref=$2
    local pkg
    for pkg in "${packages_ref[@]}"; do
        if [[ "${pkg}" == "${target}" ]]; then
            return 0
        fi
    done
    return 1
}

package_installed() {
    local pkg="$1"
    if command -v pacman >/dev/null 2>&1; then
        pacman -Q "${pkg}" >/dev/null 2>&1
        return $?
    fi
    log_error "Unsupported package manager; cannot check installation state for ${pkg}"
    exit 1
}

replace_package() {
    local current="$1" replacement="$2"
    if command -v pacman >/dev/null 2>&1; then
        log_info "Replacing installed package ${current} with ${replacement}"
        if ! run_cmd "pacman -S --noconfirm --needed ${replacement}"; then
            log_warn "Direct install failed; retrying by removing ${current} first"
            run_cmd "pacman -Rdd --noconfirm ${current}"
            run_cmd "pacman -S --noconfirm --needed ${replacement}"
        fi
        return
    fi
    log_error "Unsupported package manager; cannot replace ${current} with ${replacement}"
    exit 1
}

record_pending_args() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would record pending args to ${PENDING_ARGS_FILE}: $*"
        return
    fi
    mkdir -p "${STATE_DIR}"

    local persisted_pubkey=""
    if [[ -n "${PUBKEY_FILE}" ]]; then
        if [[ ! -f "${PUBKEY_FILE}" ]]; then
            log_error "Public key file not found: ${PUBKEY_FILE}"
            exit 1
        fi
        persisted_pubkey="${PERSISTED_PUBKEY_FILE}"
        run_cmd "install -D -m 0644 \"${PUBKEY_FILE}\" \"${persisted_pubkey}\""
        log_info "Persisted public key for resume at ${persisted_pubkey}"
    fi

    local -a resume_args=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--pubkey-file" ]]; then
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --pubkey-file when recording pending args"
                exit 1
            fi
            resume_args+=("$1")
            if [[ -n "${persisted_pubkey}" ]]; then
                resume_args+=("${persisted_pubkey}")
            else
                resume_args+=("$2")
            fi
            shift 2
            continue
        fi
        resume_args+=("$1")
        shift
    done

    printf '%q ' "${resume_args[@]}" > "${PENDING_ARGS_FILE}"
    echo >> "${PENDING_ARGS_FILE}"
}

verify_podman_runtime() {
    local runtime_output rc=0
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would verify Podman runtime as ${PODMAN_USER}"
        return
    fi
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        log_warn "Skipping Podman runtime verification because prerequisites were not satisfied."
        return
    fi
    runtime_output=$(podmin_podman_info) || rc=$?
    rc=${rc:-0}
    runtime_output=$(echo "${runtime_output:-}" | tr -d '\r')
    if [[ ${rc} -ne 0 || -z "${runtime_output}" ]]; then
        log_warn "Podman runtime check failed for ${PODMAN_USER}; see earlier errors."
        return
    fi
    if [[ "${runtime_output}" != "runc" ]]; then
        log_warn "Podman runtime reported '${runtime_output}' for ${PODMAN_USER}; expected 'runc'. Ensure containers.conf is applied."
    else
        log_info "Podman runtime verified as '${runtime_output}' for ${PODMAN_USER}"
    fi
}

status_cmd() {
    local cmd="$*"
    log_info "Status: ${cmd}"
    eval "${cmd}"
}

status_report() {
    log_info "==== STATUS REPORT ===="
    status_cmd "ss -tulnp || true"
    if command -v ufw >/dev/null 2>&1; then
        status_cmd "ufw status verbose || true"
    fi
    if systemctl list-unit-files --type=service | grep -q fail2ban.service; then
        status_cmd "systemctl status fail2ban --no-pager || true"
    fi
    report_services
    if [[ ${#BACKUP_PATHS[@]} -gt 0 ]]; then
        log_info "Backups created: ${BACKUP_PATHS[*]}"
    fi
}

final_container_checks() {
    log_info "==== FINAL CONTAINER AND PORT CHECK ===="
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would verify podmin containers and admin ports"
        return
    fi
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        log_warn "Skipping container checks because Podman prerequisites were not satisfied."
        return
    fi
    if command -v runuser >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
        run_status_capture "podman ps (as ${PODMAN_USER})" runuser -u "${PODMAN_USER}" -- podman ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'
    else
        log_warn "podman or runuser not available; skipping podman ps check"
    fi
    run_status_capture "podmin services" bash -c "systemctl --user --machine=${PODMAN_USER}@.host list-units --type=service --state=running | grep -E 'nginx-proxy-manager|gotify|uptime-kuma' || true"
    run_status_capture "admin ports listening" bash -c "ss -lntup | grep -E ':(81|3001|${GOTIFY_PORT})\\b' || true"
}


verify_nf_tables_after_reboot() {
    if [[ ${RESUME_MODE} -eq 0 ]]; then
        return
    fi
    status_cmd "lsmod | grep -E 'nf_tables|nfnetlink' || true"
}

write_continue_service() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] Would install continuation service at ${CONTINUE_SERVICE}"
        return
    fi
    render_template "${CONTINUE_SERVICE_TEMPLATE}" "${CONTINUE_SERVICE}" \
        "PENDING_ARGS_FILE=${PENDING_ARGS_FILE}" \
        "INSTALL_PREFIX=${INSTALL_PREFIX}"
    run_cmd "systemctl daemon-reload"
    run_cmd "systemctl enable vps-harden-continue.service"
}
