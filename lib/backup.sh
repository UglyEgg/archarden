# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

backup::ensure_backup_root() {
  # Purpose: Ensure backup root.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -z "${BACKUP_ROOT:-}" ]]; then
        utils::log_error "BACKUP_ROOT is not set; initialize run context before creating backups."
        exit 1
    fi
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure backup root at ${BACKUP_ROOT}"
        return
    fi
    fs::ensure_dir "${BACKUP_ROOT_BASE}" 0700 root root
    fs::ensure_dir "${BACKUP_ROOT}" 0700 root root
}

backup::init_run_dir() {
  # Purpose: Init run dir.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ -z "${RUN_ID:-}" ]]; then
        utils::log_error "RUN_ID is not set; cannot initialize backup directory."
        exit 1
    fi
    BACKUP_ROOT="${BACKUP_ROOT_BASE}/${RUN_ID}"
    backup::ensure_backup_root
}

backup::file() {
  # Purpose: File.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local file="$1" category="${2:-configs}"
    if [ -f "${file}" ]; then
        if [[ -z "${BACKUP_ROOT:-}" ]]; then
            utils::log_error "BACKUP_ROOT is not set; cannot back up ${file}"
            exit 1
        fi
        local ts rel dest_dir backup backup_name
        ts=$(date -u '+%Y%m%d%H%M%S')
        rel="${file#/}"
        backup::ensure_backup_root
        dest_dir="${BACKUP_ROOT}/${category}"
        if [[ "${rel}" == */* ]]; then
            dest_dir="${dest_dir}/$(dirname "${rel}")"
        fi
        backup_name="$(basename "${file}").${ts}.bak"
        backup="${dest_dir}/${backup_name}"
        if [ "${DRY_RUN}" -eq 1 ]; then
            utils::log_info "[DRY-RUN] Would back up ${file} to ${backup}"
            return
        fi
        fs::ensure_dir "${dest_dir}" 0700 root root
        utils::run_cmd "cp -p \"${file}\" \"${backup}\""
        BACKUP_PATHS+=("${backup}")
        utils::log_info "Backed up ${file} to ${backup}"
    fi
}
