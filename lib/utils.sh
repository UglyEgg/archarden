# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

LOG_FILE="${LOG_FILE:-/var/log/vps-harden.log}"
BACKUP_PATHS=()
DRY_RUN=${DRY_RUN:-0}

if [[ -t 1 ]]; then
    COLOR_RESET="\e[0m"
    COLOR_BOLD="\e[1m"
    COLOR_GREEN="\e[32m"
    COLOR_YELLOW="\e[33m"
    COLOR_RED="\e[31m"
    COLOR_CYAN="\e[36m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
    COLOR_CYAN=""
fi

color_text() {
    local color="$1"; shift
    printf "%b%s%b" "${color}" "$*" "${COLOR_RESET}"
}

green() { color_text "${COLOR_GREEN}" "$@"; }
yellow() { color_text "${COLOR_YELLOW}" "$@"; }
red() { color_text "${COLOR_RED}" "$@"; }
cyan() { color_text "${COLOR_CYAN}" "$@"; }
bold() { color_text "${COLOR_BOLD}" "$@"; }

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

render_template() {
    local template="$1" dest="$2"
    shift 2
    local tmp
    tmp=$(mktemp)
    cp "${template}" "${tmp}"
    for kv in "$@"; do
        local key=${kv%%=*}
        local val=${kv#*=}
        sed -i "s|__${key}__|${val}|g" "${tmp}"
    done
    write_file_atomic "${dest}" < "${tmp}"
    rm -f "${tmp}"
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi
}
