# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

runner::__error_trap() {
  # Purpose: Error trap.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local phase="$1" step="$2"
    local exit_code=$?
    local cmd=${BASH_COMMAND}
    local src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
    local line=${BASH_LINENO[0]:-0}
    utils::log_error "Step '${step}' in ${phase} failed at ${src}:${line}: ${cmd}"
    exit "${exit_code}"
}

runner::step_in_list() {
  # Purpose: Step in list.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local candidate="$1"; shift || true
    local entry
    for entry in "$@"; do
        if [[ "${candidate}" == "${entry}" && -n "${candidate}" ]]; then
            return 0
        fi
    done
    return 1
}

runner::run_steps() {
  # Purpose: Run steps.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local phase="$1" steps_var="$2"
    local -n steps_ref="${steps_var}"
    local current_step=""
    local -a selected_steps=()

    # This runner installs its own ERR trap for the duration of the step loop.
    # We intentionally do not preserve/restore any preexisting ERR trap to avoid
    # stringly-typed trap reconstruction.

    for current_step in "${steps_ref[@]}"; do
        if [[ ${#ONLY_STEPS[@]} -gt 0 ]] && ! runner::step_in_list "${current_step}" "${ONLY_STEPS[@]}"; then
            continue
        fi
        if runner::step_in_list "${current_step}" "${SKIP_STEPS[@]}"; then
            utils::log_info "Skipping step '${current_step}' in ${phase} due to --skip filter"
            continue
        fi
        selected_steps+=("${current_step}")
    done

    if [[ ${#selected_steps[@]} -eq 0 ]]; then
        utils::log_warn "No steps to run for ${phase} after filters"
        return
    fi

    trap 'runner::__error_trap "'"'"'"${phase}"'"'"'" "${CURRENT_STEP}"' ERR
    for current_step in "${selected_steps[@]}"; do
        CURRENT_STEP="${current_step}"
        utils::log_info "---- [${phase}] Starting step: ${current_step}"
        "${current_step}"
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            utils::log_error "Step '${current_step}' in ${phase} returned non-zero exit code ${rc}"
            exit "${rc}"
        fi
        utils::log_info "---- [${phase}] Completed step: ${current_step}"
    done
    trap - ERR
}
