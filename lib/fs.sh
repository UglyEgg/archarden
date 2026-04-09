# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Filesystem helpers.
#
# Mutating actions are executed via utils::run_cmd (honors DRY_RUN).

fs::ensure_dir() {
  # Purpose: Ensure a directory exists with the requested mode/owner/group (idempotent), honoring DRY_RUN.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 2 ]]; then
        utils::log_error "fs::ensure_dir <path> <mode> [owner] [group]"
        return 1
    fi

    local path="$1" mode="$2" owner="${3:-}" group="${4:-}"

    if [[ -n "${owner}" && -z "${group}" ]]; then
        utils::log_error "fs::ensure_dir: owner provided without group"
        return 1
    fi

    if [[ -n "${owner}" ]]; then
        utils::run_cmd "install -d -m ${mode} -o ${owner} -g ${group} \"${path}\""
    else
        utils::run_cmd "install -d -m ${mode} \"${path}\""
    fi
}

fs::ensure_parent_dir() {
  # Purpose: Ensure the parent directory of a target path exists with requested permissions.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 2 ]]; then
        utils::log_error "fs::ensure_parent_dir <target_path> <mode> [owner] [group]"
        return 1
    fi

    local target="$1" mode="$2" owner="${3:-}" group="${4:-}"
    local parent
    parent=$(dirname "${target}")

    fs::ensure_dir "${parent}" "${mode}" "${owner}" "${group}"
}
