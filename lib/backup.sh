# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

ensure_backup_root() {
    if [[ -z "${BACKUP_ROOT:-}" ]]; then
        log_error "BACKUP_ROOT is not set; initialize run context before creating backups."
        exit 1
    fi
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        log_info "[DRY-RUN] Would ensure backup root at ${BACKUP_ROOT}"
        return
    fi
    run_cmd "install -d -m 0700 -o root -g root \"${BACKUP_ROOT_BASE}\""
    run_cmd "install -d -m 0700 -o root -g root \"${BACKUP_ROOT}\""
}

backup_init_run_dir() {
    if [[ -z "${RUN_ID:-}" ]]; then
        log_error "RUN_ID is not set; cannot initialize backup directory."
        exit 1
    fi
    BACKUP_ROOT="${BACKUP_ROOT_BASE}/${RUN_ID}"
    ensure_backup_root
}

backup_file() {
    local file="$1" category="${2:-configs}"
    if [ -f "${file}" ]; then
        if [[ -z "${BACKUP_ROOT:-}" ]]; then
            log_error "BACKUP_ROOT is not set; cannot back up ${file}"
            exit 1
        fi
        local ts rel dest_dir backup backup_name
        ts=$(date -u '+%Y%m%d%H%M%S')
        rel="${file#/}"
        ensure_backup_root
        dest_dir="${BACKUP_ROOT}/${category}"
        if [[ "${rel}" == */* ]]; then
            dest_dir="${dest_dir}/$(dirname "${rel}")"
        fi
        backup_name="$(basename "${file}").${ts}.bak"
        backup="${dest_dir}/${backup_name}"
        if [ "${DRY_RUN}" -eq 1 ]; then
            log_info "[DRY-RUN] Would back up ${file} to ${backup}"
            return
        fi
        run_cmd "install -d -m 0700 -o root -g root \"${dest_dir}\""
        run_cmd "cp -p \"${file}\" \"${backup}\""
        BACKUP_PATHS+=("${backup}")
        log_info "Backed up ${file} to ${backup}"
    fi
}
