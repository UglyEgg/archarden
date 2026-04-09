# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Quadlet (systemd+podman) unit generation and installation helpers.
# Extracted from lib/steps.sh to keep orchestration smaller.

quadlet::configure_podman_templates() {
  # Purpose: Configure podman templates.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest_dir=/usr/share/archarden/templates/containers
    utils::write_file_atomic /usr/share/archarden/README <<'EOT'
Podman templates installed by archarden.
EOT
    utils::write_file_atomic "${dest_dir}/nginx-proxy-manager.container" < "${TEMPLATES_DIR}/containers/nginx-proxy-manager.container"
    utils::write_file_atomic "${dest_dir}/ntfy.container" < "${TEMPLATES_DIR}/containers/ntfy.container"
    utils::write_file_atomic "${dest_dir}/uptime-kuma.container" < "${TEMPLATES_DIR}/containers/uptime-kuma.container"
}

quadlet::ensure_quadlet_generator() {
  # Purpose: Ensure quadlet generator.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local generator_dir generator_path
    generator_dir=$(systemd-path user-generators 2>/dev/null || true)
    if [[ -z "${generator_dir}" ]]; then
        generator_dir="/usr/lib/systemd/user-generators"
    fi
    local -a generator_candidates=(
        "${generator_dir%/}/podman-user-generator"
    )

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would check for podman quadlet generator at: ${generator_candidates[*]}"
        return 0
    fi

    for generator_path in "${generator_candidates[@]}"; do
        if [[ -x "${generator_path}" ]]; then
            return 0
        fi
    done

    utils::log_warn "Podman user quadlet generator not found; checked: ${generator_candidates[*]}"
    utils::log_warn "Install podman with quadlet user generator support and rerun the hardener"
    return 1
}

quadlet::user_home() {
  # Purpose: User home.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local podmin_home
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ -z "${podmin_home}" ]]; then
        utils::log_error "Unable to determine home for ${PODMAN_USER}"
        exit 1
    fi
    echo "${podmin_home}"
}

quadlet::systemd_dir() {
  # Purpose: Systemd dir.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local home
    home=$(quadlet::user_home)
    echo "${home}/.config/containers/systemd"
}

quadlet::disable_archarden_quadlets() {
  # Purpose: Disable archarden quadlets.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # When quadlet processing is flaky (or a partial upgrade leaves the generator in a bad state),
  # falling back to explicit user units is more reliable than trying to debug generator output
  # on a production VPS.
    local systemd_dir ts f
    systemd_dir=$(quadlet::systemd_dir)
    ts=$(date -u '+%Y%m%d%H%M%S')

    if [[ ! -d "${systemd_dir}" ]]; then
        return 0
    fi

    for f in nginx-proxy-manager.container ntfy.container uptime-kuma.container archarden.network; do
        if [[ -f "${systemd_dir}/${f}" ]]; then
            backup::file "${systemd_dir}/${f}"
            utils::run_cmd "mv \"${systemd_dir}/${f}\" \"${systemd_dir}/${f}.disabled.${ts}\""
        fi
    done
}

quadlet::render() {
  # Purpose: Render the requested state.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local template="$1" dest="$2"
    local tmp dir
    dir=$(dirname "${dest}")
    fs::ensure_dir "${dir}" 0700 "${PODMAN_USER}" "${PODMAN_USER}" >&2
    tmp=$(mktemp)
    if [[ -f "${dest}" ]]; then
        cp "${dest}" "${tmp}"
    else
        cp "${template}" "${tmp}"
    fi
    echo "${tmp}"
}

quadlet::apply_limits() {
  # Purpose: Apply limits.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
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

    utils::write_file_atomic "${dest}" < "${tmp_out}"
    utils::ensure_file_permissions "${dest}" 0644 "${PODMAN_USER}"
    rm -f "${tmp_out}"
}

quadlet::ensure_env_var() {
  # Purpose: Ensure env var.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest="$1" key="$2" value="$3"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure quadlet Environment=${key}=... in ${dest}"
        return 0
    fi

    local tmp_out in_container=0 inserted=0
    tmp_out=$(mktemp)
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^\[.*\] ]]; then
            if [[ ${in_container} -eq 1 && ${inserted} -eq 0 ]]; then
                echo "Environment=${key}=${value}" >>"${tmp_out}"
                inserted=1
            fi
            in_container=0
        fi

        if [[ "${line}" == "[Container]" ]]; then
            in_container=1
        elif [[ ${in_container} -eq 1 && "${line}" =~ ^Environment=${key}= ]]; then
            # Drop any existing value; we'll rewrite the canonical value once per run.
            continue
        fi

        echo "${line}" >>"${tmp_out}"
    done < "${dest}"

    if [[ ${in_container} -eq 1 && ${inserted} -eq 0 ]]; then
        echo "Environment=${key}=${value}" >>"${tmp_out}"
    fi

    utils::write_file_atomic "${dest}" < "${tmp_out}"
    utils::ensure_file_permissions "${dest}" 0644 "${PODMAN_USER}"
    rm -f "${tmp_out}"
}

quadlet::ensure_install_default_target() {
  # Purpose: Ensure install default target.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
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
        {
            echo
            echo "[Install]"
            echo "WantedBy=default.target"
        } >>"${tmp_out}"
    elif [[ ${saw_install_default_target} -eq 0 ]]; then
        echo "WantedBy=default.target" >>"${tmp_out}"
    fi

    utils::write_file_atomic "${dest}" < "${tmp_out}"
    utils::ensure_file_permissions "${dest}" 0644 "${PODMAN_USER}"
    rm -f "${tmp_out}"
}

quadlet::write_unit() {
  # Purpose: Write unit.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local target="$1" source_tmp="$2"
    utils::write_file_atomic "${target}" < "${source_tmp}"
    utils::ensure_file_permissions "${target}" 0644 "${PODMAN_USER}"
}

quadlet::restart() {
  # Purpose: Restart the requested state. (systemd)
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local user="$1" service="$2"
    if [[ "${user}" == "${PODMAN_USER}" ]]; then
        if ! podman_runtime::podmin_systemctl restart "${service}"; then
            utils::log_warn "Failed to restart ${service} for ${user}; rootless services may not be active"
            return
        fi
        verify::quadlet_status "${service}"
        return
    fi
    utils::run_cmd "runuser -u ${user} -- systemctl --user restart ${service}"
}

quadlet::ensure_npm_quadlet() {
  # Purpose: Ensure npm quadlet.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local systemd_dir target tmp_out tmp_in env_dir env_file npm_admin_email npm_admin_pass
    systemd_dir=$(quadlet::systemd_dir)
    target="${systemd_dir}/nginx-proxy-manager.container"
    tmp_in=$(quadlet::render "${TEMPLATES_DIR}/containers/nginx-proxy-manager.container" "${target}")

    npm_admin_email="$(secrets::ensure_npm_admin_email)"
    npm_admin_pass="$(secrets::ensure_npm_admin_pass)"
    env_dir="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}/.config/archarden"
    if [[ -z "${env_dir}" || "${env_dir}" == "/.config/archarden" ]]; then
        env_dir="/home/${PODMAN_USER}/.config/archarden"
    fi
    env_file="${env_dir}/npm.env"
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would write ${env_file} (0600 ${PODMAN_USER}:${PODMAN_USER})"
    else
        fs::ensure_dir "${env_dir}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
        ( umask 077; printf 'INITIAL_ADMIN_EMAIL=%s
INITIAL_ADMIN_PASSWORD=%s
' "${npm_admin_email}" "${npm_admin_pass}" >"${env_file}" )
        chown "${PODMAN_USER}:${PODMAN_USER}" "${env_file}"
        chmod 0600 "${env_file}"
    fi

    tmp_out=$(mktemp)
    local in_container=0

    local -a canonical_ports=(
        "127.0.0.1:8080:80/tcp"
        "127.0.0.1:8443:443/tcp"
        "127.0.0.1:${NPM_ADMIN_BACKEND_PORT:-8181}:81/tcp"
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
                line="Network=archarden"
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





quadlet::ensure_ntfy_quadlet() {
    local target podmin_home tmp_in tmp_out desired_cache desired_data desired_cfg
    systemd_dir=$(quadlet::systemd_dir)
    target="${systemd_dir}/ntfy.container"
    tmp_in=$(quadlet::render "${TEMPLATES_DIR}/containers/ntfy.container" "${target}")
    tmp_out=$(mktemp)
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    [[ -n "${podmin_home}" ]] || { utils::log_error "Unable to determine home for ${PODMAN_USER} when preparing ntfy data dir."; rm -f "${tmp_in}" "${tmp_out}"; return 1; }
    if declare -F ntfy::ensure_runtime_config >/dev/null 2>&1; then
        ntfy::ensure_runtime_config || { rm -f "${tmp_in}" "${tmp_out}"; return 1; }
    fi
    fs::ensure_dir "${podmin_home}/.local/share/ntfy/cache" 0750 "${PODMAN_USER}" "${PODMAN_USER}" || true
    fs::ensure_dir "${podmin_home}/.local/share/ntfy/data" 0750 "${PODMAN_USER}" "${PODMAN_USER}" || true
    fs::ensure_dir "${podmin_home}/.config/archarden/ntfy" 0750 "${PODMAN_USER}" "${PODMAN_USER}" || true
    desired_cache="Volume=${podmin_home}/.local/share/ntfy/cache:/var/cache/ntfy:Z"
    desired_data="Volume=${podmin_home}/.local/share/ntfy/data:/var/lib/ntfy:Z"
    desired_cfg="Volume=${podmin_home}/.config/archarden/ntfy/server.yml:/etc/ntfy/server.yml:ro"
    awk -v desired_cache="${desired_cache}" -v desired_data="${desired_data}" -v desired_cfg="${desired_cfg}" '
        BEGIN { in_container=0; seen_cache=0; seen_data=0; seen_cfg=0 }
        /^\[Container\]/ { in_container=1; print; next }
        /^\[/ && $0 != "[Container]" { in_container=0 }
        {
            if (in_container && $0 ~ /^Volume=.*\/var\/cache\/ntfy(:Z)?$/) { if (!seen_cache) { print desired_cache; seen_cache=1 } next }
            if (in_container && $0 ~ /^Volume=.*\/var\/lib\/ntfy(:Z)?$/) { if (!seen_data) { print desired_data; seen_data=1 } next }
            if (in_container && $0 ~ /^Volume=.*\/etc\/ntfy\/server\.yml(:ro)?$/) { if (!seen_cfg) { print desired_cfg; seen_cfg=1 } next }
            print
        }
        END {
            if (!seen_cache) print desired_cache
            if (!seen_data) print desired_data
            if (!seen_cfg) print desired_cfg
        }
    ' "${tmp_in}" >"${tmp_out}"
    utils::run_cmd "install -m 0644 -o ${PODMAN_USER} -g ${PODMAN_USER} "${tmp_out}" "${target}""
    rm -f "${tmp_in}" "${tmp_out}"
}

quadlet::ensure_uptime_kuma_quadlet() {
  # Purpose: Ensure uptime kuma quadlet.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local systemd_dir target tmp_out tmp_in podmin_home data_dir
    systemd_dir=$(quadlet::systemd_dir)
    target="${systemd_dir}/uptime-kuma.container"
    tmp_in=$(quadlet::render "${TEMPLATES_DIR}/containers/uptime-kuma.container" "${target}")
    podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    if [[ -z "${podmin_home}" ]]; then
        if [[ ${DRY_RUN} -eq 1 ]]; then
            podmin_home="/home/${PODMAN_USER}"
        else
            utils::log_error "Unable to determine home for ${PODMAN_USER} when preparing uptime-kuma data dir."
            exit 1
        fi
    fi
    data_dir="${podmin_home}/.local/share/uptime-kuma"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure uptime-kuma data dir at ${data_dir}"
    else
        fs::ensure_dir "${data_dir}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
    fi

    tmp_out=$(mktemp)
    local in_container=0 saw_publish=0 saw_volume=0 saw_autoupdate=0 saw_image=0

    # Never publish Kuma on all interfaces. Bind to loopback and expose it over WireGuard
    # via root-owned systemd-socket-proxyd units.
    local bind_ip desired_publish desired_volume
    bind_ip="${WG_INTERFACE_ADDRESS%%/*}"
    if [[ -z "${bind_ip}" ]]; then
        bind_ip="${WIREGUARD_SERVER_IP:-127.0.0.1}"
    fi
    desired_publish="PublishPort=127.0.0.1:3001:3001"
    desired_volume="Volume=${podmin_home}/.local/share/uptime-kuma:/app/data:Z"

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^\[.*\] ]]; then
            if [[ ${in_container} -eq 1 ]]; then
                if [[ ${saw_image} -eq 0 ]]; then
                    echo "Image=docker.io/louislam/uptime-kuma:2" >>"${tmp_out}"
                fi
                if [[ ${saw_publish} -eq 0 ]]; then
                    echo "${desired_publish}" >>"${tmp_out}"
                fi
                if [[ ${saw_volume} -eq 0 ]]; then
                    echo "${desired_volume}" >>"${tmp_out}"
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
                line="${desired_publish}"
                saw_publish=1
            fi
            if [[ "${line}" =~ ^Volume= ]]; then
                line="${desired_volume}"
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
            echo "${desired_publish}" >>"${tmp_out}"
        fi
        if [[ ${saw_volume} -eq 0 ]]; then
            echo "${desired_volume}" >>"${tmp_out}"
        fi
        if [[ ${saw_autoupdate} -eq 0 ]]; then
            echo "AutoUpdate=registry" >>"${tmp_out}"
        fi
    fi

    quadlet::write_unit "${target}" "${tmp_out}"
    quadlet::ensure_install_default_target "${target}"
    rm -f "${tmp_in}" "${tmp_out}"
}
