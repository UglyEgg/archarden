# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

run_steps_error_trap() {
    local phase="$1" step="$2"
    local exit_code=$?
    local cmd=${BASH_COMMAND}
    local src=${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}
    local line=${BASH_LINENO[0]:-0}
    log_error "Step '${step}' in ${phase} failed at ${src}:${line}: ${cmd}"
    exit "${exit_code}"
}

step_in_list() {
    local candidate="$1"; shift || true
    local entry
    for entry in "$@"; do
        if [[ "${candidate}" == "${entry}" && -n "${candidate}" ]]; then
            return 0
        fi
    done
    return 1
}

run_steps() {
    local phase="$1" steps_var="$2"
    local -n steps_ref="${steps_var}"
    local current_step=""
    local -a selected_steps=()
    local prev_trap

    for current_step in "${steps_ref[@]}"; do
        if [[ ${#ONLY_STEPS[@]} -gt 0 ]] && ! step_in_list "${current_step}" "${ONLY_STEPS[@]}"; then
            continue
        fi
        if step_in_list "${current_step}" "${SKIP_STEPS[@]}"; then
            log_info "Skipping step '${current_step}' in ${phase} due to --skip filter"
            continue
        fi
        selected_steps+=("${current_step}")
    done

    if [[ ${#selected_steps[@]} -eq 0 ]]; then
        log_warn "No steps to run for ${phase} after filters"
        return
    fi

    prev_trap=$(trap -p ERR || true)
    trap 'run_steps_error_trap "'"${phase}"'" "${CURRENT_STEP}"' ERR
    for current_step in "${selected_steps[@]}"; do
        CURRENT_STEP="${current_step}"
        log_info "---- [${phase}] Starting step: ${current_step}"
        "${current_step}"
        log_info "---- [${phase}] Completed step: ${current_step}"
    done
    trap - ERR
    if [[ -n "${prev_trap}" ]]; then
        eval "${prev_trap}"
    fi
}
