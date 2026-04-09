# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Defaults for callers that source this library directly under `set -u` (e.g., tests).
WIREGUARD_CONFIG_LOADED=${WIREGUARD_CONFIG_LOADED:-0}

{
    # Load optional submodules used by this orchestration library.
    # shellcheck disable=SC2164
    __steps_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/systemd.sh
    source "${__steps_lib_dir}/systemd.sh"
    # shellcheck source=lib/pkg.sh
    source "${__steps_lib_dir}/pkg.sh"
    # shellcheck source=lib/notify.sh
    source "${__steps_lib_dir}/notify.sh"
    # shellcheck source=lib/net_detect.sh
    source "${__steps_lib_dir}/net_detect.sh"
    # shellcheck source=lib/socket_proxy.sh
    source "${__steps_lib_dir}/socket_proxy.sh"
    # shellcheck source=lib/podman_rootless.sh
    source "${__steps_lib_dir}/podman_rootless.sh"
    # shellcheck source=lib/quadlet.sh
    source "${__steps_lib_dir}/quadlet.sh"
    # shellcheck source=lib/wireguard.sh
    source "${__steps_lib_dir}/wireguard.sh"
    # shellcheck source=lib/wg_dnsmasq.sh
    source "${__steps_lib_dir}/wg_dnsmasq.sh"
    # shellcheck source=lib/verify.sh
    source "${__steps_lib_dir}/verify.sh"
    unset __steps_lib_dir
}

steps::read_packages_from_file() {
  # Purpose: Read non-empty, non-comment lines from a list file.
  # Inputs: $1 = file path, $2 = (optional) field number to emit (1-based). Default emits full line.
  # Outputs: Writes selected lines to stdout.
    local file="$1" field="${2:-0}"
    if [[ ! -f "${file}" ]]; then
        utils::log_error "Required list file not found: ${file}"
        return 1
    fi

    # Strip comments/blank lines; optionally emit a single whitespace-delimited field.
    if [[ "${field}" =~ ^[0-9]+$ ]] && [[ "${field}" -gt 0 ]]; then
        awk -v f="${field}" 'BEGIN{FS="[[:space:]]+"} /^[[:space:]]*(#|$)/{next} {print $f}' "${file}"
    else
        grep -Ev '^[[:space:]]*(#|$)' "${file}"
    fi
}

steps::clear_pending_state() {
  # Purpose: Clear pending state.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would clear pending state at ${PENDING_ARGS_FILE}"
        return
    fi
    rm -f "${PENDING_ARGS_FILE}"
}

steps::initialize_run_context() {
  # Purpose: Initialize run context.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local ts existing_run_id=""
    if [[ -z "${RUN_ID:-}" && ${RESUME_MODE:-0} -eq 1 ]]; then
        if [[ ! -s "${RUN_ID_FILE}" ]]; then
            utils::log_error "Resume requested but run id missing at ${RUN_ID_FILE}; run phase 0 first."
            exit 1
        fi
        existing_run_id=$(cat "${RUN_ID_FILE}")
        RUN_ID="${existing_run_id}"
        utils::log_info "Resuming with existing run id ${RUN_ID}"
    fi
    if [[ -z "${RUN_ID:-}" ]]; then
        ts=$(date -u '+%Y%m%d-%H%M%SZ')
        RUN_ID="${ts}"
        utils::log_info "Generated run id ${RUN_ID} for this execution"
    fi
    BACKUP_ROOT="${BACKUP_ROOT_BASE}/${RUN_ID}"
    BACKUP_ARCHIVE="/root/archarden-backups-${RUN_ID}.tar.gz"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would record run id at ${RUN_ID_FILE} and ensure backup root ${BACKUP_ROOT}"
        return
    fi
    fs::ensure_dir "${STATE_DIR}" 0700 root root
    utils::run_cmd "install -m 0600 /dev/null \"${RUN_ID_FILE}\""
    echo "${RUN_ID}" > "${RUN_ID_FILE}"
    backup::init_run_dir
}

steps::run_status_capture() {
  # Purpose: Run status capture.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local label="$1"; shift
    local err_file output rc err_msg
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would run: $*"
        return 0
    fi
    err_file=$(mktemp)
    rc=0
    output=$("$@" 2>"${err_file}") || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        err_msg=$(tr -d '\r' < "${err_file}" | head -n1)
        utils::log_warn "${label} failed: ${err_msg:-unknown}"
    else
        while IFS= read -r line || [[ -n "${line}" ]]; do
            utils::log_info "${label}: ${line}"
        done <<<"${output:-ok}"
    fi
    rm -f "${err_file}"
}


steps::configure_npm_admin_credentials() {
  # Purpose: Configure npm admin credentials.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local desired_email desired_pass
    desired_email="$(secrets::ensure_npm_admin_email)"
    desired_pass="$(secrets::ensure_npm_admin_pass)"

    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping NPM credential configuration because Podman prerequisites are not satisfied: ${PODMAN_PREREQ_REASON:-unknown}."
        return
    fi

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would update NPM admin credentials via API at $(npm::base_url)"
        return
    fi

    utils::require_cmd curl "curl is required to configure NPM credentials" || exit 1
    utils::require_cmd jq "jq is required to configure NPM credentials" || exit 1

    if ! npm::bootstrap_or_verify_admin "${desired_email}" "${desired_pass}"; then
        exit 1
    fi
    utils::log_info "NPM admin credentials are configured and verified."
    return

    local admin_id
    admin_id="$(npm::find_admin_user_id "${default_token}")"

    utils::log_info "Updating NPM admin credentials."
    if ! npm::set_admin_password "${default_token}" "${admin_id}" "${default_password}" "${NPM_ADMIN_PASSWORD}"; then
        utils::log_error "Failed to set NPM admin password. status=${NPM_LAST_STATUS:-unknown}"
        [[ -n "${NPM_LAST_BODY:-}" ]] && utils::log_error "NPM response: ${NPM_LAST_BODY:0:400}[truncated]"
        exit 1
    fi
    if ! npm::update_admin_email "${default_token}" "${admin_id}" "${NPM_ADMIN_EMAIL}"; then
        utils::log_error "Failed to update NPM admin email. status=${NPM_LAST_STATUS:-unknown}"
        [[ -n "${NPM_LAST_BODY:-}" ]] && utils::log_error "NPM response: ${NPM_LAST_BODY:0:400}[truncated]"
        exit 1
    fi

    if ! npm::get_token "${NPM_ADMIN_EMAIL}" "${NPM_ADMIN_PASSWORD}" >/dev/null 2>&1; then
        utils::log_error "NPM credential update did not verify. Inspect NPM logs and retry."
        exit 1
    fi
    utils::log_info "NPM admin credentials updated."
}

steps::configure_podman_api_proxy() {
  # Purpose: Configure the socket proxy for Podman API access if enabled.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if ! podman_runtime::ensure_podmin_podman_socket; then
        utils::log_warn "Skipping Podman API proxy setup because podman.socket is unavailable${PODMAN_PREREQ_REASON:+ (${PODMAN_PREREQ_REASON})}."
        return
    fi
    local podman_socket_path="/run/user/${PODMAN_UID}/podman/podman.sock"
    if [[ ! -S "${podman_socket_path}" ]]; then
        utils::log_warn "Skipping Podman API proxy setup; expected socket missing at ${podman_socket_path}"
        return
    fi
    podmin_user::ensure_podman_api_group

    local proxy_socket=/etc/systemd/system/podmin-podman.socket
    local proxy_service=/etc/systemd/system/podmin-podman.service
    local podman_socket="unix:/run/user/${PODMAN_UID}/podman/podman.sock"

    backup::file "${proxy_socket}"
    backup::file "${proxy_service}"

    utils::write_file_atomic "${proxy_socket}" <<EOT
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

    utils::write_file_atomic "${proxy_service}" <<EOT
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

[Install]
WantedBy=multi-user.target
EOT

    systemd::daemon_reload
    systemd::enable_now podmin-podman.socket
    steps::run_status_capture "podman.socket (podmin)" podman_runtime::podmin_systemctl status podman.socket --no-pager
    steps::run_status_capture "podman API proxy socket" bash -c "ss -xl | grep podmin-podman.sock || true"
    if utils::have_cmd podman && utils::have_cmd sudo && [[ -n "${USER_NAME}" ]]; then
        steps::run_status_capture "podman --remote info (as ${USER_NAME})" bash -c "sudo -u ${USER_NAME} podman --remote --url unix:///run/podmin-podman.sock info || true"
    fi
}


steps::__npm_diag_dump() {
  # Purpose: Npm diag dump.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_warn "NPM diagnostics (best effort)"
    steps::run_status_capture "NPM status" podman_runtime::podmin_systemctl status nginx-proxy-manager.service --no-pager || true
	steps::run_status_capture "NPM journal" runuser -u "${PODMAN_USER}" -- env XDG_RUNTIME_DIR="/run/user/${PODMAN_UID}" HOME="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}" journalctl --user -u nginx-proxy-manager.service -n 120 --no-pager || true
    steps::run_status_capture "Rootless containers" podman_runtime::podmin_podman ps --format 'table {{.Names}}	{{.Status}}	{{.Ports}}' || true
    steps::run_status_capture "Listening ports" ss -lntup || true
}




steps::configure_npm_public_ntfy() {
  # Purpose: Configure npm public ntfy.
    if [[ -z "${NTFY_PUBLIC_HOST}" ]]; then
        utils::log_info "No --ntfy-public-host specified; skipping public ntfy provisioning in NPM."
        return 0
    fi
    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping NPM ntfy provisioning because Podman prerequisites are not satisfied: ${PODMAN_PREREQ_REASON:-unknown}."
        return 0
    fi
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would provision ntfy public host '${NTFY_PUBLIC_HOST}' in NPM using Let's Encrypt (email: ${LE_EMAIL})."
        return 0
    fi
    utils::require_cmd curl "curl is required to provision NPM proxy hosts" || return 1
    utils::require_cmd jq "jq is required to provision NPM proxy hosts" || return 1
    local base_url token proxy_id cert_id="" attempt http_code https_code
    base_url="$(npm::base_url)"
    if ! npm::wait_ready; then
        utils::log_warn "NPM API did not become ready at ${base_url}. $(npm::error_brief)"
        steps::__npm_diag_dump
        return 0
    fi
    if ! token="$(npm::get_token "${NPM_ADMIN_EMAIL}" "${NPM_ADMIN_PASSWORD}")"; then
        utils::log_warn "Unable to authenticate to NPM API as '${NPM_ADMIN_EMAIL}' at ${base_url}. $(npm::error_brief)"
        steps::__npm_diag_dump
        return 0
    fi
    if ! podman_runtime::podmin_podman container inspect ntfy >/dev/null 2>&1; then
        utils::log_warn "ntfy container not found yet (name: ntfy). Skipping ntfy public provisioning in NPM for now."
        return 0
    fi
    if ! proxy_id="$(npm::ensure_proxy_host "${token}" "${NTFY_PUBLIC_HOST}" "ntfy" 80 0 false)"; then
        utils::log_warn "Failed to create/update NPM proxy host for '${NTFY_PUBLIC_HOST}'. $(npm::error_brief)"
        return 0
    fi
    : "${proxy_id}"
    for attempt in 1 2 3; do
        if cert_id="$(npm::ensure_letsencrypt_certificate "${token}" "${NTFY_PUBLIC_HOST}" "${LE_EMAIL}")"; then
            break
        fi
        utils::log_warn "Let's Encrypt certificate issuance attempt ${attempt}/3 failed for '${NTFY_PUBLIC_HOST}'. $(npm::error_brief)"
        sleep 10
    done
    if [[ -z "${cert_id}" ]]; then
        utils::log_warn "Certificate issuance did not complete for '${NTFY_PUBLIC_HOST}'. Proxy host was created without TLS."
        return 0
    fi
    if ! npm::ensure_proxy_host "${token}" "${NTFY_PUBLIC_HOST}" "ntfy" 80 "${cert_id}" true >/dev/null; then
        utils::log_warn "Certificate created (id=${cert_id}) but failed to attach it to proxy host '${NTFY_PUBLIC_HOST}'. $(npm::error_brief)"
        return 0
    fi
    http_code="$(http::http_code "http://127.0.0.1:8080/" -H "Host: ${NTFY_PUBLIC_HOST}")"
    https_code="$(http::http_code "https://${NTFY_PUBLIC_HOST}/" -k --resolve "${NTFY_PUBLIC_HOST}:443:127.0.0.1" --max-time 8 --connect-timeout 3)"
    utils::log_info "ntfy proxy checks (local): http=${http_code} https=${https_code}"
    utils::log_info "ntfy is now exposed via NPM at https://${NTFY_PUBLIC_HOST}"
}

steps::configure_notifications() {
  # Purpose: Configure Archarden notification plumbing and periodic reports.
    if [[ -n "${NTFY_PUBLIC_HOST}" ]]; then
        steps::configure_npm_public_ntfy
    fi
    notify::install_notify_script
    notify::install_units
    notify::enable_units
}


steps::discover_public_ipv4() {
  # Purpose: Discover public ipv4.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") print $(i+1)}' | head -n1)
    if [[ -z "${ip}" ]]; then
        ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {sub("/.*","",$2); print $2}' | head -n1)
    fi
    echo "${ip}"
}

steps::__ensure_grub_defaults_saved() {
  # Purpose: Ensure grub defaults saved.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure /etc/default/grub has GRUB_DEFAULT=saved and GRUB_SAVEDEFAULT=true"
        return
    fi
    if [[ ! -f /etc/default/grub ]]; then
        utils::log_error "/etc/default/grub not found; cannot set GRUB_DEFAULT/GRUB_SAVEDEFAULT."
        exit 1
    fi
    backup::file /etc/default/grub
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
        utils::run_cmd "sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub"
    else
        utils::run_cmd "echo 'GRUB_DEFAULT=saved' >> /etc/default/grub"
    fi
    if grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub; then
        utils::run_cmd "sed -i 's/^GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub"
    else
        utils::run_cmd "echo 'GRUB_SAVEDEFAULT=true' >> /etc/default/grub"
    fi
}

steps::ensure_lts_kernel_and_reboot_gate() {
  # Purpose: Ensure lts kernel and reboot gate.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::require_cmd grub-mkconfig "grub-mkconfig not found; unable to set linux-lts as default." || exit 1
    utils::require_cmd grub-set-default "grub-set-default not found; unable to set linux-lts as default." || exit 1
    utils::require_cmd grub-editenv "grub-editenv not found; unable to verify default boot entry." || exit 1

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would fully upgrade, install linux-lts, regenerate GRUB, set default to '${GRUB_LTS_ENTRY}', verify grub-editenv, and require reboot before hardening."
        return
    fi

    local current_kernel saved_entry
    current_kernel=$(uname -r)
    saved_entry=$(grub-editenv list 2>/dev/null | awk -F= '/^saved_entry=/{print $2}' || true)

    if [[ "${current_kernel}" == *-lts ]] && [[ "${saved_entry}" == "${GRUB_LTS_ENTRY}" ]]; then
        utils::log_info "System already booted into linux-lts with GRUB default set; continuing with hardening."
        return
    fi

    utils::log_info "Pre-hardening: updating system and preparing linux-lts default boot entry."
    if ! {
        utils::run_cmd "pacman -Syu --noconfirm"
        utils::run_cmd "pacman -S --needed --noconfirm linux-lts"
        steps::__ensure_grub_defaults_saved
        utils::run_cmd "grub-mkconfig -o ${GRUB_CONFIG_PATH}"
        utils::run_cmd "grub-set-default \"${GRUB_LTS_ENTRY}\""
    }; then
        utils::log_error "$(utils::red "linux-lts installation failed; please review ${LOG_FILE}")"
        exit 1
    fi

    saved_entry=$(grub-editenv list 2>/dev/null | awk -F= '/^saved_entry=/{print $2}' || true)
    if [[ "${saved_entry}" != "${GRUB_LTS_ENTRY}" ]]; then
        utils::log_error "Expected GRUB saved_entry '${GRUB_LTS_ENTRY}', but grub-editenv reported '${saved_entry:-<unset>}'"
        exit 1
    fi

    steps::__record_pending_args "${INVOCATION_ARGS[@]}"
    steps::__write_continue_service
    local pending_args
    pending_args="$(<"${PENDING_ARGS_FILE}")"

    local resume_cmd
    # shellcheck disable=SC2086
    resume_cmd="${INSTALL_BIN} --resume ${pending_args}"
    utils::log_warn "$(utils::yellow "Reboot required: linux-lts installed and set as default. Rebooting will auto-resume hardening via systemd.")"
    utils::log_info "Manual resume command: ${resume_cmd}"
    utils::log_info "$(utils::green "LTS kernel installed. Rebooting in 5 seconds.")"
    sleep 5
    utils::run_cmd "reboot"
}

steps::switch_to_phase1_logging() {
  # Purpose: Switch to phase1 logging.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -z "${RUN_ID:-}" ]]; then
        if [[ ! -s "${RUN_ID_FILE}" ]]; then
            utils::log_error "Resume requested but run id missing at ${RUN_ID_FILE}; run phase 0 first."
            exit 1
        fi
        RUN_ID=$(cat "${RUN_ID_FILE}")
        BACKUP_ROOT="${BACKUP_ROOT_BASE}/${RUN_ID}"
        BACKUP_ARCHIVE="/root/archarden-backups-${RUN_ID}.tar.gz"
        utils::log_info "Loaded run id ${RUN_ID} for phase 1 resume"
    fi
    export CURRENT_PHASE="phase1"
    LOG_FILE="${PHASE1_LOG}"
    export LOG_FILE
    utils::log_info "==== Starting Phase 1 actions (logging to ${LOG_FILE}) ===="
}

steps::__run_as_user() {
  # Purpose: Run as user.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local user="$1"; shift
    local cmd="$*"
    local uid runtime_dir
    uid=$(id -u "${user}")
    runtime_dir="/run/user/${uid}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] (as ${user}) ${cmd}"
        return 0
    fi
    if [[ ! -d "${runtime_dir}" ]]; then
        utils::log_warn "Runtime directory ${runtime_dir} missing for ${user}; ensure logind is managing the session."
    fi
    utils::log_info "Running as ${user}: ${cmd}"
    set +e
	HOME="$(getent passwd "${user}" | cut -d: -f6)" XDG_RUNTIME_DIR="${runtime_dir}" runuser -l "${user}" -c "${cmd}"
    local rc=$?
    set -e
    return ${rc}
}

steps::final_summary() {
  # Purpose: Print a final status/next-steps summary for the operator.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "==== ✅ Hardening completed ===="
    local summary output_dir
    summary=$(
        cat <<EOF
✅ Hardening completed successfully.
$( (( ENABLE_FIREWALL )) && echo "🔒 Firewall: configured (ufw)" || echo "🔓 Firewall: skipped")
$( (( ENABLE_FAIL2BAN )) && echo "🛡️ Fail2ban: enabled" || echo "🛡️ Fail2ban: skipped")
🐧 Kernel: $(uname -r)
📦 Packages updated and installed.
🧰 Templates installed to /usr/share/archarden/templates/containers
🔑 WireGuard client configs: ${STATE_DIR}/wireguard/clients/*.conf
📜 Log: ${LOG_FILE}
🧪 Verify exposure: sudo ${INSTALL_BIN} verify
🔐 Stage 2 lockdown (after VPN verified): sudo ${INSTALL_BIN} lockdown
EOF
    )
    if [[ -n "${USER_NAME}" ]] && id -u "${USER_NAME}" >/dev/null 2>&1; then
        output_dir="/home/${USER_NAME}"
    else
        output_dir="/root"
    fi
    FINAL_LOG_FILE="${output_dir}/archarden.log"
    echo "${summary}" > "${FINAL_LOG_FILE}"
    if [[ -n "${USER_NAME}" ]] && id -u "${USER_NAME}" >/dev/null 2>&1; then
        chown "${USER_NAME}:${USER_NAME}" "${FINAL_LOG_FILE}"
    fi
    utils::log_info "Summary written to ${FINAL_LOG_FILE}"
}

steps::write_user_readme() {
  # Purpose: Write user readme. (firewall)
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local target_user="${USER_NAME}" target_home readme_path alt_readme marker dest vpn_ip domain_suffix npm_port="${NPM_ADMIN_PORT:-8181}" kuma_port=3001 wg_client_dir="${STATE_DIR}/wireguard/clients"
    marker="${README_MARKER}"
    vpn_ip="${WIREGUARD_SERVER_IP:-${WG_INTERFACE_ADDRESS%%/*}}"
    if [[ -z "${vpn_ip}" ]]; then
        vpn_ip="10.66.66.1"
    fi
    domain_suffix="$(wireguard::server_shortname)"
    if [[ -z "${domain_suffix}" ]]; then
        domain_suffix="server"
    fi
    if [[ -z "${target_user}" ]]; then
        utils::log_warn "No target user specified; skipping README generation"
        return
    fi
    target_home=$(getent passwd "${target_user}" | cut -d: -f6)
    if [[ -z "${target_home}" ]]; then
        utils::log_error "Unable to determine home directory for ${target_user}"
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
    local ntfy_note
    if [[ -n "${NTFY_PUBLIC_HOST}" ]]; then
        ntfy_note="- ntfy (public): https://${NTFY_PUBLIC_HOST}
  - Notification env: /etc/archarden/notify.env
  - Topic secret: /var/lib/archarden/secrets/ntfy_topic
  - Admin credentials: /var/lib/archarden/secrets/ntfy_admin_user + ntfy_admin_pass"
    else
        ntfy_note="- ntfy: expose it via NPM using --ntfy-public-host ntfy.<public-domain> and --le-email <you@domain>"
    fi

    local content
    content=$(cat <<EOF
${marker}
# archarden: next steps after reboot

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
- These rules are configured by archarden. Verify:
  - sudo ufw status verbose
  - ss -lntup | grep -E ':(${npm_port}|${kuma_port})\\b' || true
  - (Optional) External scans should NOT show these ports.

## 3. Connect to admin services (after VPN is up)
- Use a browser (or SSH tunnel if preferred) after VPN is up to configure each service:
  - NPM Admin: http://npm.${domain_suffix}:${npm_port} (or http://${vpn_ip}:${npm_port})
  - Uptime Kuma: http://kuma.${domain_suffix}:${kuma_port} (or http://${vpn_ip}:${kuma_port})
${ntfy_note}

## 4. Stage 2 lockdown (recommended after verifying VPN works)
- This tightens SSH to WireGuard only and binds sshd to the wg0 interface.
- Apply lockdown:
  - sudo ${INSTALL_BIN} lockdown
- Verify exposure:
  - sudo ${INSTALL_BIN} verify
- To undo lockdown:
  - sudo ${INSTALL_BIN} lockdown --revert
EOF
)
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would write ${dest} for ${target_user}"
		# shellcheck disable=SC2001
        echo "${content}" | sed 's/^/    /' >&2
        return
    fi
    utils::write_file_atomic "${dest}" <<< "${content}"
    utils::run_cmd "chown ${target_user}:${target_user} \"${dest}\""
    utils::run_cmd "chmod 0644 \"${dest}\""
    utils::log_info "User README written to ${dest}"
}

steps::archive_backups() {
  # Purpose: Archive backups created during the run into the backup root.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    backup::ensure_backup_root
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would archive backups from ${BACKUP_ROOT} to ${BACKUP_ARCHIVE}"
        return
    fi
    if [[ ! -d "${BACKUP_ROOT}" ]]; then
        fs::ensure_dir "${BACKUP_ROOT}" 0700 root root
    fi
    if [[ -f "${BACKUP_ARCHIVE}" ]]; then
        utils::run_cmd "rm -f \"${BACKUP_ARCHIVE}\""
    fi
    utils::run_cmd "umask 077 && tar -C /root -czf \"${BACKUP_ARCHIVE}\" \"archarden-backups/${RUN_ID}\""
    utils::run_cmd "chown root:root \"${BACKUP_ARCHIVE}\""
    utils::run_cmd "chmod 0600 \"${BACKUP_ARCHIVE}\""
    utils::log_info "Backups archived at ${BACKUP_ARCHIVE}"
    utils::log_info "Backup directory retained at ${BACKUP_ROOT}"
}

steps::trigger_final_reboot() {
  # Purpose: Trigger the final reboot if required by the chosen configuration.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "==== Phase 1 completed; entering final reboot step ===="
    utils::log_info "Phase 1 will intentionally end via system reboot. A 'Completed step: steps::trigger_final_reboot' line is not expected because the reboot terminates the current run."
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would reboot now to complete Phase 1"
        return
    fi
    utils::log_info "Rebooting in 5 seconds to finalize services and quadlets."
    sleep 5
    utils::log_info "Issuing reboot now."
    utils::run_cmd "reboot"
}

steps::install_packages() {
  # Purpose: Install/replace required packages to reach the desired baseline.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local pkgs=()
    while IFS= read -r pkg; do
        pkgs+=("${pkg}")
    done < <(pkg::read_list "${CONFIG_DIR}/packages.list")

    if [[ ${ENABLE_AUDITD} -eq 1 ]]; then
        while IFS= read -r pkg; do
            pkgs+=("${pkg}")
        done < <(pkg::read_list "${CONFIG_DIR}/packages.auditd.list" 1)
    fi

    while IFS= read -r pkg; do
        pkgs+=("${pkg}")
    done < <(pkg::read_list "${CONFIG_DIR}/packages.custom.list" 1)

    pkg::apply_replacements pkgs "${CONFIG_DIR}/packages.replacements.list"
    pkg::install_list "${pkgs[@]}"
}

steps::install_self() {
  # Purpose: Install Archarden onto the host (binaries, libs, templates, configs).
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would install archarden to ${INSTALL_PREFIX} and symlink to ${INSTALL_BIN}"
        return
    fi
    if [[ "${SCRIPT_DIR}" != "${INSTALL_PREFIX}" ]]; then
        mkdir -p "${INSTALL_PREFIX}"
        utils::run_cmd "cp -a ${SCRIPT_DIR}/. ${INSTALL_PREFIX}/"
    fi
    utils::run_cmd "install -m 0755 ${INSTALL_PREFIX}/archarden ${INSTALL_BIN}"
}

steps::next_available_system_gid() {
  # Purpose: Next available system gid.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
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



steps::preflight() {
  # Purpose: Validate baseline prerequisites and host assumptions before making changes.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::require_root
    if [[ -z "${SYSTEM_HOSTNAME}" ]]; then
        utils::log_error "--hostname is required."
        exit 1
    fi
    if [[ -z "${USER_NAME}" ]]; then
        utils::log_error "--user is required."
        exit 1
    fi
    if [[ -z "${PUBKEY_FILE}" && -z "${PUBKEY_VALUE}" ]]; then
        utils::log_error "Either --pubkey-file or --pubkey is required."
        exit 1
    fi

    if [[ -n "${NTFY_PUBLIC_HOST}" ]]; then
        if [[ -z "${LE_EMAIL}" ]]; then
            utils::log_error "--le-email is required when --ntfy-public-host is set (needed for Let's Encrypt)."
            exit 1
        fi
        if ! [[ "${NTFY_PUBLIC_HOST}" =~ ^[A-Za-z0-9.-]+$ ]]; then
            utils::log_error "Invalid --ntfy-public-host '${NTFY_PUBLIC_HOST}'."
            exit 1
        fi
    fi
    if ! grep -qi 'arch' /etc/os-release; then
        utils::log_error "This tool is intended for Arch Linux systems."
        exit 1
    fi
    if ! [[ ${SSH_PORT} =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        utils::log_error "Invalid --ssh-port '${SSH_PORT}'. Must be 1-65535."
        exit 1
    fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        SSH_CONNECTION_INFO=${SSH_CONNECTION}
        utils::log_info "Running under SSH from ${SSH_CONNECTION_INFO}"
    else
        utils::log_warn "Not running under SSH; lockout protections limited."
    fi
}

steps::finalize_resume_state() {
  # Purpose: Finalize resume state.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Clean up reboot continuation mechanism after Phase 1 completes.
  # Safe to run even when not resuming; it becomes a best-effort no-op.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would clear pending resume state and disable archarden-continue.service"
        return
    fi

    utils::log_info "Clearing pending resume state so archarden-continue.service cannot start again on the next boot."
    # Remove pending args so the continuation unit cannot run again.
    rm -f "${PENDING_ARGS_FILE}" 2>/dev/null || true

    # Do not mutate the currently running continuation unit from inside its own
    # start job. Removing or reloading the unit while it is still activating can
    # leave systemd marking the start operation as timed out even though the
    # script itself is healthy. The ConditionPathExists guard on the unit is
    # sufficient: with no pending args file present, the unit will be skipped on
    # subsequent boots.
    utils::log_info "Leaving archarden-continue.service installed and loaded for the remainder of the current run. Future boots will skip it because ${PENDING_ARGS_FILE} has been removed."
}

# Package list parsing/replacement primitives moved to lib/pkg.sh.

steps::__record_pending_args() {
  # Purpose: Record pending args.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would record pending args to ${PENDING_ARGS_FILE}: $*"
        return
    fi
    mkdir -p "${STATE_DIR}"

    local persisted_pubkey=""
    if [[ -n "${PUBKEY_FILE}" ]]; then
        if [[ ! -f "${PUBKEY_FILE}" ]]; then
            utils::log_error "Public key file not found: ${PUBKEY_FILE}"
            exit 1
        fi
        persisted_pubkey="${PERSISTED_PUBKEY_FILE}"
        utils::run_cmd "install -D -m 0644 \"${PUBKEY_FILE}\" \"${persisted_pubkey}\""
        utils::log_info "Persisted public key for resume at ${persisted_pubkey}"
    fi

    local -a resume_args=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--pubkey-file" ]]; then
            if [[ $# -lt 2 ]]; then
                utils::log_error "Missing value for --pubkey-file when recording pending args"
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

steps::status_cmd() {
  # Purpose: Status cmd.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::log_info "Status: $*"
    # Callers sometimes pass a full command line as a single string. If so,
    # run it through a shell; otherwise execute argv directly.
    if [[ $# -eq 1 ]]; then
        bash -lc "$1" || true
    else
        "$@" || true
    fi
}

steps::collect_global_addrs() {
  # Purpose: Collect global addrs.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local -n v4_ref=$1
    local -n v6_ref=$2
    v4_ref=()
    v6_ref=()

    if utils::have_cmd ip; then
        # shellcheck disable=SC2034
        mapfile -t v4_ref < <(ip -o -4 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u)
        # shellcheck disable=SC2034
        mapfile -t v6_ref < <(ip -o -6 addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u)
    fi
}

steps::__write_continue_service() {
  # Purpose: Write continue service.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would install continuation service at ${CONTINUE_SERVICE}"
        return
    fi
    utils::render_template "${CONTINUE_SERVICE_TEMPLATE}" "${CONTINUE_SERVICE}" \
        "PENDING_ARGS_FILE=${PENDING_ARGS_FILE}" \
        "INSTALL_PREFIX=${INSTALL_PREFIX}"
    systemd::daemon_reload
    systemd::enable archarden-continue.service
}

steps::bootstrap_service_admins() {
  # Purpose: Bootstrap service admin credentials during normal phase1 provisioning.
    local npm_email npm_pass

    if [[ ${PODMAN_PREREQS_READY} -eq 0 ]]; then
        utils::log_warn "Skipping service admin bootstrap because Podman prerequisites are not satisfied: ${PODMAN_PREREQ_REASON:-unknown}."
        return 0
    fi

    npm_email="$(secrets::ensure_npm_admin_email)"
    npm_pass="$(secrets::ensure_npm_admin_pass)"

    if ! npm::bootstrap_or_verify_admin "${npm_email}" "${npm_pass}"; then
        return 1
    fi
    utils::log_info "NPM admin credentials are configured and verified."

    if declare -F kuma::ensure_admin_credentials >/dev/null 2>&1; then
        kuma::ensure_admin_credentials || return 1
    fi
    if declare -F ntfy::ensure_runtime_config >/dev/null 2>&1; then
        ntfy::ensure_runtime_config || return 1
        ntfy::restart_service || {
            utils::log_error "ntfy runtime configuration was written but the service did not become ready."
            return 1
        }
        utils::log_info "ntfy runtime configuration, credentials, and publisher token are configured."
    fi
    return 0
}
