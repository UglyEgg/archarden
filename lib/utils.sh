#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/vps-harden.log"
BACKUP_PATHS=()
DRY_RUN=${DRY_RUN:-0}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local line="${ts} [${level}] ${msg}"
    echo "${line}"
    if [ -w "$(dirname "${LOG_FILE}")" ] || [ ! -e "${LOG_FILE}" ]; then
        mkdir -p "$(dirname "${LOG_FILE}")"
        echo "${line}" >>"${LOG_FILE}"
    fi
}

log_info() { log INFO "$*"; }
log_warn() { log WARN "$*"; }
log_error() { log ERROR "$*"; }

run_cmd() {
    local cmd="$*"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "[DRY-RUN] ${cmd}"
        return 0
    fi
    log_info "Running: ${cmd}"
    eval "${cmd}"
}

backup_file() {
    local file="$1"
    if [ -f "${file}" ]; then
        local ts
        ts=$(date -u '+%Y%m%d%H%M%S')
        local backup="${file}.${ts}.bak"
        run_cmd "cp -p ${file} ${backup}"
        BACKUP_PATHS+=("${backup}")
        log_info "Backed up ${file} to ${backup}"
    fi
}

write_file_atomic() {
    local dest="$1"
    local tmp
    tmp=$(mktemp)
    cat >"${tmp}"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "[DRY-RUN] Would write to ${dest}:"
        sed 's/^/    /' "${tmp}" >&2
        rm -f "${tmp}"
        return 0
    fi
    install -D -m 0644 "${tmp}" "${dest}"
    rm -f "${tmp}"
}

append_if_missing() {
    local file="$1" line="$2"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_info "[DRY-RUN] Would ensure line in ${file}: ${line}"
        return 0
    fi
    grep -qxF "${line}" "${file}" 2>/dev/null && return 0
    echo "${line}" >>"${file}"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

