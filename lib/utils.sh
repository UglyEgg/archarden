#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

LOG_FILE="${LOG_FILE:-/var/log/archarden.log}"
# shellcheck disable=SC2034  # collected for reporting in steps
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

# Terminal color codes are treated as constants.
readonly COLOR_RESET COLOR_BOLD COLOR_GREEN COLOR_YELLOW COLOR_RED COLOR_CYAN

utils::__on_err() {
  # Purpose: Emit a high-signal error report when a command fails under strict mode.
  # Inputs: None (reads bash error context variables).
  # Outputs: Writes a stack trace and failure context to stderr.
  #
  # Notes:
  # - Requires "set -E" / errtrace for function/module attribution.
  # - Must be safe under "set -e" (never fail inside the handler).
  # When invoked from an ERR trap, $? is not reliable in all bash contexts
  # (notably command substitutions). Prefer an explicit rc argument when
  # provided by the trap.
  local rc="${1:-$?}"

  # Disable strict behavior inside the trap handler.
  set +e
  set +u

  local cmd="${2:-${BASH_COMMAND-<unknown>}}"
  local src="${BASH_SOURCE[1]-${BASH_SOURCE[0]-<unknown>}}"
  local line="${BASH_LINENO[0]-?}"
  local func="${FUNCNAME[1]-${FUNCNAME[0]-<toplevel>}}"

  {
    printf "\n"
    printf "ERROR: rc=%s\n" "${rc}"
    printf "  cmd: %s\n" "${cmd}"
    printf "  at : %s:%s in %s()\n" "${src}" "${line}" "${func}"
    printf "  stack:\n"

    # Most-recent call first. Index 0 is this handler.
    local i
    for ((i=1; i<${#FUNCNAME[@]}; i++)); do
      local fn="${FUNCNAME[$i]-<unknown>}"
      local fsrc="${BASH_SOURCE[$i]-<unknown>}"
      local fln="${BASH_LINENO[$((i-1))]-?}"
      printf "    #%s %s() at %s:%s\n" "$i" "${fn}" "${fsrc}" "${fln}"
    done
    printf "\n"
  } >&2

  return "${rc}"
}

utils::install_err_trap() {
  # Purpose: Install the canonical ERR trap so failures report module/file/line and stack trace.
  # Inputs: None.
  # Outputs: Installs an ERR trap; no stdout.
  trap 'utils::__on_err "$?" "$BASH_COMMAND"' ERR
}

utils::__color_text() {
  # Purpose: Color text.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local color="$1"; shift
    printf "%b%s%b" "${color}" "$*" "${COLOR_RESET}"
}

utils::green() { utils::__color_text "${COLOR_GREEN}" "$@"; }
utils::yellow() { utils::__color_text "${COLOR_YELLOW}" "$@"; }
utils::red() { utils::__color_text "${COLOR_RED}" "$@"; }
utils::cyan() { utils::__color_text "${COLOR_CYAN}" "$@"; }
utils::bold() { utils::__color_text "${COLOR_BOLD}" "$@"; }

utils::log() {
  # Purpose: Log.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local line="${ts} [${level}] ${msg}"
    echo "${line}"

    local dir
    dir="$(dirname "${LOG_FILE}")"
    # Best-effort utils::log file append. Do not fail when LOG_FILE points to an unwritable location.
    if [[ -w "${dir}" ]] || [[ -e "${LOG_FILE}" && -w "${LOG_FILE}" ]]; then
        mkdir -p "${dir}" 2>/dev/null || true
        echo "${line}" >>"${LOG_FILE}" 2>/dev/null || true
    fi
}


utils::log_info() { utils::log INFO "$*"; }
utils::log_warn() { utils::log WARN "$*"; }
utils::log_error() { utils::log ERROR "$*"; }

utils::run_cmd() {
  # Purpose: Execute a command (or log it in DRY_RUN), preserving safe quoting and consistent logging.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local cmd="$*"
    if [ "${DRY_RUN}" -eq 1 ]; then
        utils::log_info "[DRY-RUN] ${cmd}"
        return 0
    fi
    utils::log_info "Running: ${cmd}"
    if [ "$#" -eq 1 ]; then
        bash -c "$1"
    else
        "$@"
    fi
}

utils::write_file_atomic() {
  # Purpose: Write content to a file atomically (render to temp, then move/install), honoring DRY_RUN.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest="$1"
    local tmp
    tmp=$(mktemp)
    cat >"${tmp}"
    if [ "${DRY_RUN}" -eq 1 ]; then
        utils::log_info "[DRY-RUN] Would write to ${dest}:"
        sed 's/^/    /' "${tmp}" >&2
        rm -f "${tmp}"
        return 0
    fi
    install -D -m 0644 "${tmp}" "${dest}"
    rm -f "${tmp}"
}

utils::append_if_missing() {
  # Purpose: Append if missing.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local file="$1" line="$2"
    if [ "${DRY_RUN}" -eq 1 ]; then
        utils::log_info "[DRY-RUN] Would ensure line in ${file}: ${line}"
        return 0
    fi
    grep -qxF "${line}" "${file}" 2>/dev/null && return 0
    echo "${line}" >>"${file}"
}

utils::render_template() {
  # Purpose: Render a template file by substituting placeholders, writing the rendered content to stdout.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
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
    utils::write_file_atomic "${dest}" < "${tmp}"
    rm -f "${tmp}"
}

# Install a rendered template to a destination.
# Placeholders use __KEY__ tokens substituted via KEY=VAL args.
utils::__template_render_to_tmp() {
  # Purpose: Template render to tmp.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local template_path="$1" tmp_out="$2"
    shift 2

    cp "${template_path}" "${tmp_out}"
    local kv key val
    for kv in "$@"; do
        key=${kv%%=*}
        val=${kv#*=}
        sed -i "s|__${key}__|${val}|g" "${tmp_out}"
    done
}

utils::__resolve_template_path() {
  # Purpose: Resolve template path.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local template_rel="$1"

    if [[ -f "${template_rel}" ]]; then
        printf '%s\n' "${template_rel}"
        return 0
    fi

    if [[ -n "${SCRIPT_DIR:-}" && -f "${SCRIPT_DIR}/${template_rel}" ]]; then
        printf '%s\n' "${SCRIPT_DIR}/${template_rel}"
        return 0
    fi

    if [[ -n "${TEMPLATES_DIR:-}" ]]; then
        local stripped="${template_rel#templates/}"
        if [[ -f "${TEMPLATES_DIR}/${stripped}" ]]; then
            printf '%s\n' "${TEMPLATES_DIR}/${stripped}"
            return 0
        fi
    fi

    utils::log_error "Template not found: ${template_rel}"
    return 1
}

# Usage: utils::install_template_root_file <template_relpath> <dst_abs> <mode> <owner> <group> [KEY=VAL ...]
utils::install_template_root_file() {
  # Purpose: Render a template and install it to a root-owned destination with mode/owner/group.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local template_rel="$1" dst="$2" mode="$3" owner="$4" group="$5"
    shift 5

    local template_path
    template_path="$(utils::__resolve_template_path "${template_rel}")" || return 1

    local tmp
    tmp=$(mktemp)
    utils::__template_render_to_tmp "${template_path}" "${tmp}" "$@"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would install template ${template_rel} -> ${dst} (${mode} ${owner}:${group})"
        sed 's/^/    /' "${tmp}" >&2
        rm -f "${tmp}"
        return 0
    fi

    utils::run_cmd "install -D -m ${mode} -o ${owner} -g ${group} \"${tmp}\" \"${dst}\""
    rm -f "${tmp}"
}

# Usage: utils::install_template_user_file <template_relpath> <dst_abs> <mode> [KEY=VAL ...]
utils::install_template_user_file() {
  # Purpose: Render a template and install it to a user-owned destination with mode.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local template_rel="$1" dst="$2" mode="$3"
    shift 3

    local template_path
    template_path="$(utils::__resolve_template_path "${template_rel}")" || return 1

    local tmp
    tmp=$(mktemp)
    utils::__template_render_to_tmp "${template_path}" "${tmp}" "$@"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would install template ${template_rel} -> ${dst} (${mode})"
        sed 's/^/    /' "${tmp}" >&2
        rm -f "${tmp}"
        return 0
    fi

    utils::run_cmd "install -D -m ${mode} \"${tmp}\" \"${dst}\""
    rm -f "${tmp}"
}


utils::ensure_file_permissions() {
  # Purpose: Ensure file permissions.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local path="$1" mode="$2" owner="$3" group="${4:-$3}"
    utils::run_cmd "chown ${owner}:${group} ${path}"
    utils::run_cmd "chmod ${mode} ${path}"
}

utils::write_config_from_repo() {
  # Purpose: Write config from repo.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local dest="$1" source_rel="$2"
    backup::file "${dest}"
    utils::write_file_atomic "${dest}" < "${CONFIG_DIR}/${source_rel}"
}

utils::ensure_file_exists() {
  # Purpose: Ensure file exists.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local path="$1" mode="$2" owner="$3" group="${4:-$3}"
    shift 4 || true
    local has_stdin=1
    if [[ -t 0 ]]; then
        has_stdin=0
    fi
    if [[ ! -f "${path}" ]]; then
        local tmp
        tmp=$(mktemp)
        if [[ ${has_stdin} -eq 1 ]]; then
            cat > "${tmp}"
        else
            : > "${tmp}"
        fi
        utils::write_file_atomic "${path}" < "${tmp}"
        rm -f "${tmp}"
    elif [[ ${has_stdin} -eq 1 ]]; then
        cat >/dev/null || true
    fi
    utils::ensure_file_permissions "${path}" "${mode}" "${owner}" "${group}"
}


utils::have_cmd() {
  # Purpose: Have cmd.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    command -v "$1" >/dev/null 2>&1
}

# Usage: utils::require_cmd <cmd> [message]
# Returns 0 if command exists; otherwise logs message and returns 1.
utils::require_cmd() {
  # Purpose: Require cmd.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local cmd="$1"; shift
    local msg
    if [[ $# -gt 0 ]]; then
        msg="$*"
    else
        msg="Required command not found: ${cmd}"
    fi
    if utils::have_cmd "${cmd}"; then
        return 0
    fi
    utils::log_error "${msg}"
    return 1
}

utils::require_root() {
  # Purpose: Fail fast if the current process is not running as root.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [ "$(id -u)" -ne 0 ]; then
        utils::log_error "This script must be run as root."
        exit 1
    fi
}
