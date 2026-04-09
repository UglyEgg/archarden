# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash


{
    # shellcheck disable=SC2164
    __podman_rootless_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/podmin_user.sh
    source "${__podman_rootless_lib_dir}/podmin_user.sh"
    # shellcheck source=lib/podman_runtime.sh
    source "${__podman_rootless_lib_dir}/podman_runtime.sh"
    unset __podman_rootless_lib_dir
}

# Rootless Podman + quadlet/fallback provisioning for the 'podmin' user.
# Extracted from lib/steps.sh to keep orchestration smaller.

podman_rootless::_ensure_network() {
  # Purpose: Ensure network.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Quadlet network units are not consistently supported across Podman/systemd builds.
  # Create the shared network imperatively and reference it by name in container quadlets.
    local net_name="archarden"
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping podman network creation because Podman prerequisites are not satisfied: ${PODMAN_PREREQ_REASON:-unknown}."
        return 0
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure rootless Podman network '${net_name}' exists for ${PODMAN_USER}."
        return 0
    fi
    if podman_runtime::podmin_podman network inspect "${net_name}" >/dev/null 2>&1; then
        return 0
    fi
    utils::log_info "Creating rootless Podman network '${net_name}' for ${PODMAN_USER}."
    if ! podman_runtime::podmin_podman network create --label app=archarden "${net_name}" >/dev/null; then
        utils::log_warn "Failed to create Podman network '${net_name}'. Containers may not be able to resolve each other by name."
        return 1
    fi
    return 0
}

podman_rootless::ensure_prereqs() {
  # Purpose: Ensure prereqs.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    PODMAN_PREREQS_READY=1
    PODMAN_PREREQ_REASON=""
    if ! podmin_user::ensure_subordinate_ids; then
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"failed to ensure subordinate ID ranges for ${PODMAN_USER}"}
    fi
    if ! podman_runtime::ensure_podmin_config_dir; then
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"failed to ensure ${PODMAN_USER} config directory ownership"}
    fi
    podmin_user::ensure_userns_sysctl
    if ! podman_runtime::ensure_podmin_user_manager; then
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"user manager not available for ${PODMAN_USER} (no user bus)"}
        return 0
    fi
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        return 0
    fi
    if ! podman_runtime::podmin_podman_info >/dev/null; then
        PODMAN_PREREQS_READY=0
        utils::log_warn "Podman prerequisites not met; podman info failed for ${PODMAN_USER}."
        return 0
    fi
}

podman_rootless::__check_duplicate_publish_ports() {
  # Purpose: Check duplicate publish ports.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest="$1"
    local line value
    declare -A seen=()
    local -a publish_lines=() duplicates=()

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would check for duplicate PublishPort entries in ${dest}"
        return
    fi

    if [[ ! -f "${dest}" ]]; then
        utils::log_warn "PublishPort check skipped; ${dest} not found"
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
        utils::log_error "Duplicate PublishPort entries detected in ${dest}: ${duplicates[*]}"
        utils::log_error "PublishPort lines:"
        for value in "${publish_lines[@]}"; do
            utils::log_error "  ${value}"
        done
        exit 1
    fi
}

podman_rootless::configure_quadlets() {
  # Purpose: Configure quadlets. (systemd)
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local systemd_dir
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping rootless quadlet configuration because Podman prerequisites are not satisfied: ${PODMAN_PREREQ_REASON:-unknown}."
        return
    fi
    if ! quadlet::ensure_quadlet_generator; then
        utils::log_warn "Quadlet generator unavailable; falling back to explicit systemd user units (no quadlet parsing)."
        podman_rootless::__configure_units_fallback
        return
    fi

    podman_rootless::_ensure_network || true
    quadlet::ensure_npm_quadlet
    quadlet::ensure_ntfy_quadlet
    quadlet::ensure_uptime_kuma_quadlet
    systemd_dir=$(quadlet::systemd_dir)
    podman_rootless::__check_duplicate_publish_ports "${systemd_dir}/nginx-proxy-manager.container"

    if ! podman_runtime::ensure_podmin_user_manager; then
        utils::log_warn "User manager unavailable for ${PODMAN_USER}; skipping quadlet activation."
        PODMAN_PREREQS_READY=0
        PODMAN_PREREQ_REASON=${PODMAN_PREREQ_REASON:-"user manager unavailable for ${PODMAN_USER}"}
        return
    fi
    if ! podman_runtime::podmin_systemctl daemon-reload; then
        utils::log_warn "Failed to reload user systemd daemon for ${PODMAN_USER}; rootless services may not be active"
        return
    fi
    podman_runtime::podmin_systemctl reset-failed || true
    podman_runtime::podmin_systemctl daemon-reload || true

    local services=(
        nginx-proxy-manager.service
        ntfy.service
        uptime-kuma.service
    )
    local had_failure=0
    local service container_file container_path
    local i
    for service in "${services[@]}"; do
        container_file="${service%.service}.container"
        container_path="${systemd_dir}/${container_file}"
        if [[ ! -f "${container_path}" ]]; then
            utils::log_warn "Unit ${container_file} not found under ${systemd_dir}; cannot start ${service}"
            utils::run_cmd "ls -la ${systemd_dir} | grep -E 'nginx-proxy-manager|ntfy|uptime-kuma' || true"
            had_failure=1
            continue
        fi
        if podman_runtime::podmin_systemctl enable --now "${service}"; then
            # systemd may return success while the unit is still transitioning. Wait briefly
            # so dependent steps (socket proxies, NPM API calls) don't trip over boot races.
            for ((i=0; i<60; i++)); do
                if systemctl --user --machine="${PODMAN_USER}@.host" is-active --quiet "${service}" >/dev/null 2>&1; then
                    break
                fi
                sleep 0.5
            done
            steps::run_status_capture "${service} status" podman_runtime::podmin_systemctl status "${service}" --no-pager
        else
            if [[ "${PODMIN_SYSTEMCTL_LAST_ERR:-}" =~ (transient|generated) ]]; then
                utils::log_info "Quadlet unit ${service} appears transient/generated; switching to fallback user units."
            else
                utils::log_warn "Failed to enable/start ${service}; collecting diagnostics."
            fi
            had_failure=1
            steps::run_status_capture "${service} status" podman_runtime::podmin_systemctl status "${service}" --no-pager || true
			steps::run_status_capture "${service} journal" runuser -u "${PODMAN_USER}" -- env XDG_RUNTIME_DIR="/run/user/${PODMAN_UID}" HOME="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}" journalctl --user -u "${service}" -n 200 --no-pager || true
        fi
    done

    # Reduce first-boot races where systemd reports a unit active but the container
    # still hasn't bound its localhost ports yet (common on small VPS instances).
    # Warn-only: this is readiness hardening, not a functional gate.
    if [[ ${had_failure} -eq 0 ]]; then
        net_detect::wait_for_local_tcp_listen "127.0.0.1" 8080 20 "npm backend (http)" || true
        net_detect::wait_for_local_tcp_listen "127.0.0.1" 8443 20 "npm backend (https)" || true
        net_detect::wait_for_local_tcp_listen "127.0.0.1" "${NPM_ADMIN_BACKEND_PORT:-8181}" 20 "npm backend (admin)" || true
        net_detect::wait_for_local_tcp_listen "127.0.0.1" 2586 20 "ntfy backend" || true
    net_detect::wait_for_local_tcp_listen "127.0.0.1" 3001 20 "uptime-kuma backend" || true
    fi

    if [[ ${had_failure} -eq 1 ]]; then
        utils::log_warn "One or more quadlet-managed services failed to start. Switching to fallback systemd user units."
        # Stop any partially started quadlet units first to avoid port conflicts.
        podman_runtime::podmin_systemctl disable --now nginx-proxy-manager.service ntfy.service uptime-kuma.service >/dev/null 2>&1 || true
        quadlet::disable_archarden_quadlets
        podman_runtime::podmin_systemctl daemon-reload >/dev/null 2>&1 || true
        podman_rootless::__configure_units_fallback || true
    fi
}

podman_rootless::__configure_units_fallback() {
  # Purpose: Configure units fallback.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # This fallback avoids quadlet entirely. It is used when the user-generator is missing.
  # It still requires a functioning user systemd instance for ${PODMAN_USER}.
    local home_dir runtime_dir unit_dir bind_ip mgmt_bind_ip
    local net_name="archarden"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would write explicit systemd user units for rootless Podman containers (fallback mode)."
        return 0
    fi

    podman_runtime::ensure_podmin_user_manager || return 1
    runtime_dir="/run/user/${PODMAN_UID}"
    home_dir="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
    unit_dir="${home_dir}/.config/systemd/user"
    fs::ensure_dir "${unit_dir}" 0700 "${PODMAN_USER}" "${PODMAN_USER}"

    # Ensure shared network exists.
    podman_rootless::_ensure_network || true

    mgmt_bind_ip="${WG_INTERFACE_ADDRESS%%/*}"
    if [[ -z "${mgmt_bind_ip}" ]]; then
        mgmt_bind_ip="${WIREGUARD_SERVER_IP:-127.0.0.1}"
    fi
    bind_ip="${WG_INTERFACE_ADDRESS%%/*}"
    if [[ -z "${bind_ip}" ]]; then
        bind_ip="${WIREGUARD_SERVER_IP:-127.0.0.1}"
    fi

    # nginx-proxy-manager
    local npm_email npm_pass env_dir npm_env_file
    npm_email="$(secrets::ensure_npm_admin_email)"
    npm_pass="$(secrets::ensure_npm_admin_pass)"

    env_dir="${home_dir}/.config/archarden"
    npm_env_file="${env_dir}/npm.env"
    fs::ensure_dir "${env_dir}" 0700 "${PODMAN_USER}" "${PODMAN_USER}"
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would write ${npm_env_file} (0600 ${PODMAN_USER}:${PODMAN_USER}) with NPM bootstrap defaults."
    else
        utils::write_file_atomic "${npm_env_file}" <<EENV
INITIAL_ADMIN_EMAIL=${npm_email}
INITIAL_ADMIN_PASSWORD=${npm_pass}
EENV
        utils::ensure_file_permissions "${npm_env_file}" 0600 "${PODMAN_USER}"
    fi

    utils::write_file_atomic "${unit_dir}/nginx-proxy-manager.service" <<EOT
[Unit]
Description=Nginx Proxy Manager (rootless, fallback)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${home_dir}
Environment=XDG_RUNTIME_DIR=${runtime_dir}
EnvironmentFile=${npm_env_file}
ExecStartPre=-/usr/bin/podman network create --label app=archarden ${net_name}
ExecStartPre=/usr/bin/podman network inspect ${net_name}
ExecStart=/usr/bin/podman run --name npm --replace --network ${net_name} --network-alias npm -p 127.0.0.1:8080:80/tcp -p 127.0.0.1:8443:443/tcp -p 127.0.0.1:${NPM_ADMIN_BACKEND_PORT:-8181}:81/tcp --env-file ${npm_env_file} -v npm-data:/data -v npm-letsencrypt:/etc/letsencrypt --memory=512m --pids-limit=512 --memory-swap=1g --label io.containers.autoupdate=registry docker.io/jc21/nginx-proxy-manager:latest
ExecStop=/usr/bin/podman stop -t 10 npm
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOT
    utils::ensure_file_permissions "${unit_dir}/nginx-proxy-manager.service" 0644 "${PODMAN_USER}"
    # ntfy
    local ntfy_cache_dir ntfy_data_dir ntfy_cfg_dir
    ntfy_cache_dir="${home_dir}/.local/share/ntfy/cache"
    ntfy_data_dir="${home_dir}/.local/share/ntfy/data"
    ntfy_cfg_dir="${home_dir}/.config/archarden/ntfy"
    if declare -F ntfy::ensure_runtime_config >/dev/null 2>&1; then
        ntfy::ensure_runtime_config || return 1
    fi
    fs::ensure_dir "${ntfy_cache_dir}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
    fs::ensure_dir "${ntfy_data_dir}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
    fs::ensure_dir "${ntfy_cfg_dir}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
    utils::write_file_atomic "${unit_dir}/ntfy.service" <<EOT
[Unit]
Description=ntfy (rootless, fallback)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${home_dir}
Environment=XDG_RUNTIME_DIR=${runtime_dir}
WorkingDirectory=%h
ExecStartPre=/usr/bin/bash -lc '/usr/bin/podman network exists ${net_name} || /usr/bin/podman network create --label app=archarden ${net_name}'
ExecStartPre=/usr/bin/podman network inspect ${net_name}
ExecStart=/usr/bin/podman run --name ntfy --replace --network ${net_name} --network-alias ntfy -p 127.0.0.1:2586:80/tcp -v ${ntfy_cache_dir}:/var/cache/ntfy:Z -v ${ntfy_data_dir}:/var/lib/ntfy:Z -v ${ntfy_cfg_dir}/server.yml:/etc/ntfy/server.yml:ro --memory=128m --pids-limit=256 --label io.containers.autoupdate=registry docker.io/binwiederhier/ntfy:latest serve
ExecStop=/usr/bin/podman stop -t 10 ntfy
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOT
    utils::ensure_file_permissions "${unit_dir}/ntfy.service" 0644 "${PODMAN_USER}"

    # uptime-kuma
    local data_dir
    data_dir="${home_dir}/.local/share/uptime-kuma"
    fs::ensure_dir "${data_dir}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
    utils::write_file_atomic "${unit_dir}/uptime-kuma.service" <<EOT
[Unit]
Description=Uptime Kuma (rootless, fallback)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=${home_dir}
Environment=XDG_RUNTIME_DIR=${runtime_dir}
ExecStartPre=-/usr/bin/podman network create --label app=archarden ${net_name}
ExecStartPre=/usr/bin/podman network inspect ${net_name}
ExecStartPre=/usr/bin/sh -lc 'tmp="${data_dir}/db-config.json.tmp"; printf "%s\n" '''{"type":"sqlite"}''' > "$$tmp" && chmod 0644 "$$tmp" && mv -f "$$tmp" "${data_dir}/db-config.json"'
ExecStart=/usr/bin/podman run --name uptime-kuma --replace --network ${net_name} --network-alias uptime-kuma -p 127.0.0.1:3001:3001/tcp -v ${data_dir}:/app/data:Z --label io.containers.autoupdate=registry docker.io/louislam/uptime-kuma:2
ExecStop=/usr/bin/podman stop -t 10 uptime-kuma
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
EOT
    utils::ensure_file_permissions "${unit_dir}/uptime-kuma.service" 0644 "${PODMAN_USER}"

    # Activate
    podman_runtime::podmin_systemctl daemon-reload || true
    podman_runtime::podmin_systemctl enable --now nginx-proxy-manager.service ntfy.service uptime-kuma.service || true
    local i svc
    for svc in nginx-proxy-manager.service ntfy.service uptime-kuma.service; do
        for ((i=0; i<60; i++)); do
            if systemctl --user --machine="${PODMAN_USER}@.host" is-active --quiet "${svc}" >/dev/null 2>&1; then
                break
            fi
            sleep 0.5
        done
    done
    steps::run_status_capture "nginx-proxy-manager.service status" podman_runtime::podmin_systemctl status nginx-proxy-manager.service --no-pager || true
        steps::run_status_capture "ntfy.service status" podman_runtime::podmin_systemctl status ntfy.service --no-pager || true
    steps::run_status_capture "uptime-kuma.service status" podman_runtime::podmin_systemctl status uptime-kuma.service --no-pager || true

    # Same readiness hardening as quadlet mode: reduce first-boot races where the
    # unit is active but the container hasn't bound its localhost ports yet.
    net_detect::wait_for_local_tcp_listen "127.0.0.1" 8080 20 "npm backend (http)" || true
    net_detect::wait_for_local_tcp_listen "127.0.0.1" 8443 20 "npm backend (https)" || true
    net_detect::wait_for_local_tcp_listen "127.0.0.1" "${NPM_ADMIN_BACKEND_PORT:-8181}" 20 "npm backend (admin)" || true
    net_detect::wait_for_local_tcp_listen "127.0.0.1" 2586 20 "ntfy backend" || true
    net_detect::wait_for_local_tcp_listen "127.0.0.1" 3001 20 "uptime-kuma backend" || true
}

podman_rootless::run_final_checks() {
  # Purpose: Run final checks. (systemd)
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "==== FINAL CONTAINER AND PORT CHECK ===="
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would verify podmin containers and admin ports"
        return
    fi
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping container checks because Podman prerequisites were not satisfied."
        return
    fi
    if utils::have_cmd runuser && utils::have_cmd podman; then
        local home_dir
        home_dir="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
        steps::run_status_capture "podman ps (as ${PODMAN_USER})" runuser -u "${PODMAN_USER}" -- bash -lc "cd \"${home_dir}\" && podman ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'"
    else
        utils::log_warn "podman or runuser not available; skipping podman ps check"
    fi
    steps::run_status_capture "podmin services" bash -c "systemctl --user --machine=${PODMAN_USER}@.host list-units --type=service --state=running | grep -E 'nginx-proxy-manager|ntfy|uptime-kuma' || true"
    steps::run_status_capture "admin ports listening" bash -c "ss -lntup | grep -E ':(${NPM_ADMIN_BACKEND_PORT:-8181}|3001)\\b' || true"
}


# --- Additional rootless/podmin helpers extracted from lib/steps.sh ---
