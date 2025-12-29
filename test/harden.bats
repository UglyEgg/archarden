#!/usr/bin/env bats

setup_file() {
  set -euo pipefail
}

setup() {
  PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export LOG_FILE="${BATS_TEST_TMPDIR}/test.log"
}

@test "run_cmd logs dry-run behavior and skips execution" {
  export DRY_RUN=1
  source "${PROJECT_ROOT}/lib/utils.sh"

  tmp_file="${BATS_TEST_TMPDIR}/dry_run_output"
  run run_cmd "echo should_not_write > \"${tmp_file}\""

  [ "$status" -eq 0 ]
  [ ! -f "${tmp_file}" ]
  [[ "${output}" == *"[DRY-RUN]"* ]]
}

@test "render_template substitutes placeholders" {
  export DRY_RUN=0
  source "${PROJECT_ROOT}/lib/utils.sh"

  template="${BATS_TEST_TMPDIR}/template.conf"
  dest="${BATS_TEST_TMPDIR}/output.conf"
  cat <<'TEMPLATE' >"${template}"
name=__NAME__
port=__PORT__
TEMPLATE

  run render_template "${template}" "${dest}" "NAME=myapp" "PORT=8080"

  [ "$status" -eq 0 ]
  grep -qx "name=myapp" "${dest}"
  grep -qx "port=8080" "${dest}"
}

@test "ensure_backup_root issues creation commands for base and run directories" {
  export DRY_RUN=0
  source "${PROJECT_ROOT}/lib/utils.sh"
  source "${PROJECT_ROOT}/lib/backup.sh"

  call_log="${BATS_TEST_TMPDIR}/run_cmd_calls"
  run_cmd() {
    echo "$*" >>"${call_log}"
  }

  BACKUP_ROOT_BASE="${BATS_TEST_TMPDIR}/backups"
  BACKUP_ROOT="${BACKUP_ROOT_BASE}/run-id"

  run ensure_backup_root

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

  run run_steps "phaseX" steps

  [ "$status" -eq 0 ]
  [[ -f "${executed}" ]]
  [[ "$(cat "${executed}")" == "first" ]]
  [[ "${output}" == *"Skipping step 'third' in phaseX due to --skip filter"* ]]
}
