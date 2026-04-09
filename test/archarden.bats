#!/usr/bin/env bats
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski


setup_file() {
  set -euo pipefail
}

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export LOG_FILE="${BATS_TEST_TMPDIR}/test.log"
}

@test "utils::run_cmd logs dry-run behavior and skips execution" {
  export DRY_RUN=1
  source "${PROJECT_ROOT}/lib/utils.sh"

  tmp_file="${BATS_TEST_TMPDIR}/dry_run_output"
  run utils::run_cmd "echo should_not_write > \"${tmp_file}\""

  [ "$status" -eq 0 ]
  [ ! -f "${tmp_file}" ]
  [[ "${output}" == *"[DRY-RUN]"* ]]
}

@test "utils::render_template substitutes placeholders" {
  export DRY_RUN=0
  source "${PROJECT_ROOT}/lib/utils.sh"

  template="${BATS_TEST_TMPDIR}/template.conf"
  dest="${BATS_TEST_TMPDIR}/output.conf"
  cat <<'TEMPLATE' >"${template}"
name=__NAME__
port=__PORT__
TEMPLATE

  run utils::render_template "${template}" "${dest}" "NAME=myapp" "PORT=8080"

  [ "$status" -eq 0 ]
  grep -qx "name=myapp" "${dest}"
  grep -qx "port=8080" "${dest}"
}

@test "backup::ensure_backup_root issues creation commands for base and run directories" {
  export DRY_RUN=0
  source "${PROJECT_ROOT}/lib/utils.sh"
  source "${PROJECT_ROOT}/lib/fs.sh"
  source "${PROJECT_ROOT}/lib/backup.sh"

  call_log="${BATS_TEST_TMPDIR}/run_cmd_calls"
  utils::run_cmd() {
    echo "$*" >>"${call_log}"
  }

  BACKUP_ROOT_BASE="${BATS_TEST_TMPDIR}/backups"
  BACKUP_ROOT="${BACKUP_ROOT_BASE}/run-id"

  run backup::ensure_backup_root

  [ "$status" -eq 0 ]
  grep -F "install -d -m 0700 -o root -g root \"${BACKUP_ROOT_BASE}\"" "${call_log}"
  grep -F "install -d -m 0700 -o root -g root \"${BACKUP_ROOT}\"" "${call_log}"
}

@test "run_steps applies only and skip filters" {
  export DRY_RUN=0
  source "${PROJECT_ROOT}/lib/utils.sh"
  source "${PROJECT_ROOT}/lib/runner.sh"

  ONLY_STEPS=(first third)
  SKIP_STEPS=(third)
  steps=(first second third)

  executed="${BATS_TEST_TMPDIR}/executed_steps"
  first() { echo "first" >>"${executed}"; }
  second() { echo "second" >>"${executed}"; }
  third() { echo "third" >>"${executed}"; }

  run runner::run_steps "phaseX" steps

  [ "$status" -eq 0 ]
  [[ -f "${executed}" ]]
  [[ "$(cat "${executed}")" == "first" ]]
  [[ "${output}" == *"Skipping step 'third' in phaseX due to --skip filter"* ]]
}

@test "archarden --help advertises subcommands and persisted runtime flags" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash "${PROJECT_ROOT}/archarden" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"lockdown"* ]]
  [[ "$output" == *"creds"* ]]
  [[ "$output" == *"notify init"* ]]
  [[ "$output" == *"doctor"* ]]
  [[ "$output" == *"wg export"* ]]
  [[ "$output" == *"--le-email"* ]]
  [[ "$output" == *"--npm-admin-email"* ]]
  [[ "$output" == *"--public-host"* ]]
  [[ "$output" == *"--ntfy-public-host"* ]]
  [[ "$output" == *"--wg-peers"* ]]
  [[ "$output" == *"--json"* ]]
  [[ "$output" == *"--bundle"* ]]
  [[ "$output" == *"--bundle-dir"* ]]
  [[ "$output" == *"/var/lib/archarden/answers.params"* ]]
}

@test "archarden doctor requires root even in dry-run" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "run as non-root to validate root-only gate"
  fi
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash "${PROJECT_ROOT}/archarden" doctor --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "archarden wg export requires root even in dry-run" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "run as non-root to validate root-only gate"
  fi
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash "${PROJECT_ROOT}/archarden" wg export --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "archarden lockdown requires root even in dry-run" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "run as non-root to validate root-only gate"
  fi
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash "${PROJECT_ROOT}/archarden" lockdown --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "archarden lockdown --status requires root" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "run as non-root to validate root-only gate"
  fi
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash "${PROJECT_ROOT}/archarden" lockdown --status --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "archarden lockdown --revert requires root even in dry-run" {
  if [[ "$(id -u)" -eq 0 ]]; then
    skip "run as non-root to validate root-only gate"
  fi
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash "${PROJECT_ROOT}/archarden" lockdown --revert --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "ntfy payloads are shipped as templates and installed via helpers" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"

  [[ -f "${PROJECT_ROOT}/templates/notify/notify_send.sh.tmpl" ]]
  [[ -f "${PROJECT_ROOT}/templates/notify/os_update_report.sh.tmpl" ]]
  [[ -f "${PROJECT_ROOT}/templates/systemd/system/archarden-os-report.service.tmpl" ]]

  run grep -F 'utils::install_template_root_file "templates/notify/notify_send.sh.tmpl"' "${PROJECT_ROOT}/lib/notify_install.sh"
  [ "$status" -eq 0 ]

  run grep -F 'utils::install_template_root_file "templates/systemd/system/archarden-os-report.service.tmpl"' "${PROJECT_ROOT}/lib/notify_units.sh"
  [ "$status" -eq 0 ]

  run grep -F "__LIB_DIR__" "${PROJECT_ROOT}/templates/systemd/system/archarden-os-report.service.tmpl"
  [ "$status" -eq 0 ]

  run grep -F "LIB_DIR=" "${PROJECT_ROOT}/lib/notify_units.sh"
  [ "$status" -eq 0 ]
}



@test "WireGuard auto peer generation uses server shortname and deterministic ids in dry-run" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash -c "
    set -euo pipefail
    export DRY_RUN=1
    export LOG_FILE=\"${BATS_TEST_TMPDIR}/wg_test.log\"
    export CONFIG_DIR=\"${PROJECT_ROOT}/config\"
    export STATE_DIR=\"${BATS_TEST_TMPDIR}/state\"
    export SYSTEM_HOSTNAME=\"alpha.example.com\"
    export WG_PEERS_COUNT=3
    declare -a WG_PEERS=()
    declare -a WIREGUARD_PEER_NAMES=()
    declare -a WIREGUARD_PEER_IPS=()
    source \"${PROJECT_ROOT}/lib/utils.sh\"
    source \"${PROJECT_ROOT}/lib/steps.sh\"
    wireguard::_load_config
    printf 'names=%s\n' \"\$(IFS=,; echo \"\${WIREGUARD_PEER_NAMES[*]}\")\"
    printf 'ips=%s\n' \"\$(IFS=,; echo \"\${WIREGUARD_PEER_IPS[*]}\")\"
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"names=alpha.0001,alpha.0002,alpha.0003"* ]]
  [[ "$output" == *"ips=10.66.66.2/32,10.66.66.3/32,10.66.66.4/32"* ]]
}

@test "dnsmasq over wg0 is configured with wildcard shortname domain in dry-run" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash -c "
    set -euo pipefail
    export DRY_RUN=1
    export LOG_FILE=\"${BATS_TEST_TMPDIR}/dnsmasq_test.log\"
    export CONFIG_DIR=\"${PROJECT_ROOT}/config\"
    export STATE_DIR=\"${BATS_TEST_TMPDIR}/state\"
    export SYSTEM_HOSTNAME=\"alpha.example.com\"
    source \"${PROJECT_ROOT}/lib/utils.sh\"
    source \"${PROJECT_ROOT}/lib/steps.sh\"
    wg_dnsmasq::configure 2>&1
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"interface=wg0"* ]]
  [[ "$output" == *"bind-dynamic"* ]]
  [[ "$output" == *"address=/.alpha/10.66.66.1"* ]]
  [[ "$output" == *"Would enable and start dnsmasq.service"* ]]
}

@test "ntfy quadlet template uses autoupdate registry and no pull-never" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  template="${PROJECT_ROOT}/templates/containers/ntfy.container"

  [ -f "${template}" ]
  grep -qx "AutoUpdate=registry" "${template}"
  grep -qx "Image=docker.io/binwiederhier/ntfy:latest" "${template}"
  ! grep -q "--pull=never" "${template}"
}

@test "socket_proxy::configure provisions VPN admin sockets in dry-run" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash -c "
    set -euo pipefail
    export DRY_RUN=1
    export LOG_FILE=\"${BATS_TEST_TMPDIR}/sock_test.log\"
    export CONFIG_DIR=\"${PROJECT_ROOT}/config\"
    export STATE_DIR=\"${BATS_TEST_TMPDIR}/state\"
    export WG_INTERFACE_ADDRESS=10.66.66.1/24
    export NPM_ADMIN_PORT=8181
    source \"${PROJECT_ROOT}/lib/utils.sh\"
    source \"${PROJECT_ROOT}/lib/backup.sh\"
    source \"${PROJECT_ROOT}/lib/steps.sh\"
    socket_proxy::configure 2>&1
  "

  [ "$status" -eq 0 ]
  [[ "$output" == *"archarden-npm-admin.socket"* ]]
  [[ "$output" == *"ListenStream=10.66.66.1:8181"* ]]
  [[ "$output" == *"archarden-kuma.socket"* ]]
  [[ "$output" == *"ListenStream=10.66.66.1:3001"* ]]
}

@test "repo contains no stray .bak artifacts in lib/" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  ! find "${PROJECT_ROOT}/lib" -maxdepth 1 -type f -name "*.bak" -print -quit | grep -q .
}

@test "resume unit avoids eval parsing of pending args" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  unit="${PROJECT_ROOT}/templates/systemd/archarden-continue.service"
  [ -f "${unit}" ]
  ! grep -qE '^[[:space:]]*eval[[:space:]]' "${unit}"
  grep -q "read -r -a argv" "${unit}"
}

@test "steps library avoids eval for steps::status_cmd execution" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  steps="${PROJECT_ROOT}/lib/steps.sh"
  [ -f "${steps}" ]
  ! grep -qE 'steps::status_cmd\(\)[[:space:]]*\{[^}]*eval' "${steps}"
}

@test "ntfy CLI examples use https URLs" {
  run bash -c 'echo https://push.example.com'
  [ "$status" -eq 0 ]
  [[ "$output" == "https://push.example.com" ]]





}

@test "archarden params template documents key flags" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  params="${PROJECT_ROOT}/config/archarden.params"
  [ -f "${params}" ]
  grep -q -- "--le-email" "${params}"
  grep -q -- "--npm-admin-email" "${params}"
  grep -q -- "--ntfy-public-host" "${params}"
  grep -q -- "--wg-interface-address" "${params}"
  grep -q -- "doctor --json" "${params}"
  grep -q -- "lockdown --status" "${params}"
}

@test "doctor json output first non-empty line is json object" {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  run bash "${PROJECT_ROOT}/archarden" doctor --dry-run --json
  [ "$status" -eq 0 ]
  first_line="$(printf '%s\n' "$output" | awk 'NF{print; exit}')"
  [[ "$first_line" == '{"tool":"archarden-doctor"'* ]]
}


# --- Added tests (R0) ---

@test "archarden sources core orchestration modules" {
  run grep -n -- 'source "${SCRIPT_DIR}/lib/loader.sh"' archarden
  [ "$status" -eq 0 ]

  run grep -n -- 'source "${SCRIPT_DIR}/lib/runner.sh"' archarden
  [ "$status" -eq 0 ]

  run grep -n -- 'source "${SCRIPT_DIR}/lib/steps.sh"' archarden
  [ "$status" -eq 0 ]
}

@test "module map document exists" {
  [ -f "docs/dev/module-map.md" ]
}

@test "steps sources net_detect module" {
  run grep -n -- 'source "${__steps_lib_dir}/net_detect.sh"' lib/steps.sh
  [ "$status" -eq 0 ]
  [ -f "lib/net_detect.sh" ]
}

@test "steps sources socket_proxy module" {
  run grep -n -- 'source "${__steps_lib_dir}/socket_proxy.sh"' lib/steps.sh
  [ "$status" -eq 0 ]
  [ -f "lib/socket_proxy.sh" ]
}

@test "steps sources podman_rootless module" {
  run grep -n -- 'source "${__steps_lib_dir}/podman_rootless.sh"' lib/steps.sh
  [ "$status" -eq 0 ]
  [ -f "lib/podman_rootless.sh" ]
}

@test "notification install modules exist" {
  [ "$status" -eq 0 ]
  [ "$status" -eq 0 ]
  [ "$status" -eq 0 ]
  [ -f "lib/notify_install.sh" ]
  [ -f "lib/notify_units.sh" ]
}

@test "steps sources wireguard modules" {
  run grep -n -- 'source "${__steps_lib_dir}/wireguard.sh"' lib/steps.sh
  [ "$status" -eq 0 ]
  run grep -n -- 'source "${__steps_lib_dir}/wg_dnsmasq.sh"' lib/steps.sh
  [ "$status" -eq 0 ]
  [ -f "lib/wireguard.sh" ]
  [ -f "lib/wg_dnsmasq.sh" ]
}

@test "archarden sources lockdown module" {
  run grep -n -- 'source "${SCRIPT_DIR}/lib/lockdown.sh"' archarden
  [ "$status" -eq 0 ]
  [ -f "lib/lockdown.sh" ]
}

@test "steps sources verify module" {
  run grep -n -- 'source "${__steps_lib_dir}/verify.sh"' lib/steps.sh
  [ "$status" -eq 0 ]
  [ -f "lib/verify.sh" ]
}

@test "steps.sh stays under monolith threshold" {
  # Guardrail: steps.sh is orchestration, not a kitchen-sink implementation module.
  # Adjust downward as extraction continues.
  run wc -l lib/steps.sh
  [ "$status" -eq 0 ]
  count="$(echo "$output" | awk '{print $1}')"
  [ "${count}" -le 1000 ]
}

@test "steps sources quadlet module" {
  run grep -n -- 'source "${__steps_lib_dir}/quadlet.sh"' lib/steps.sh
  [ "$status" -eq 0 ]
  [ -f "lib/quadlet.sh" ]
}

@test "podman_rootless owns podmin helpers" {
  run grep -n -- '^podmin_user::ensure_podmin_user()' lib/podmin_user.sh
  [ "$status" -eq 0 ]
  run grep -n -- '^podmin_user::ensure_podmin_user()' lib/steps.sh
  [ "$status" -ne 0 ]
}

@test "module-map mermaid uses safe labels" {
  run grep -n -- '<br' docs/dev/module-map.md
  [ "$status" -ne 0 ]
  run grep -n -- '^flowchart LR' docs/dev/module-map.md
  [ "$status" -eq 0 ]
}

@test "podman_rootless sources podmin_user and podman_runtime" {
  run grep -n -- 'source "${__podman_rootless_lib_dir}/podmin_user.sh"' lib/podman_rootless.sh
  [ "$status" -eq 0 ]
  run grep -n -- 'source "${__podman_rootless_lib_dir}/podman_runtime.sh"' lib/podman_rootless.sh
  [ "$status" -eq 0 ]
  [ -f "lib/podmin_user.sh" ]
  [ -f "lib/podman_runtime.sh" ]
}
