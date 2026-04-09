# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# systemd lifecycle helpers (system units).
#
# Mutating actions are executed via utils::run_cmd (honors DRY_RUN).
# Read-only queries run directly (safe even in DRY_RUN).

systemd::have_systemctl() {
  # Purpose: Have systemctl.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    utils::have_cmd systemctl
}

systemd::__require_systemctl() {
  # Purpose: Require systemctl.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if ! systemd::have_systemctl; then
        utils::log_warn "systemctl not found; cannot perform systemd operation"
        return 1
    fi
}

systemd::__ctl() {
  # Purpose: Ctl.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${DRY_RUN:-0} -eq 0 ]]; then
        systemd::__require_systemctl || return 1
    fi
    utils::run_cmd systemctl "$@"
}

systemd::__query() {
  # Purpose: Query.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    systemd::__require_systemctl || return 1
    systemctl "$@"
}

systemd::daemon_reload() {
  # Purpose: Reload systemd manager configuration (systemctl daemon-reload).
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    systemd::__ctl daemon-reload
}

systemd::enable_now() {
  # Purpose: Enable and start a systemd unit immediately (systemctl enable --now).
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 1 ]]; then
        utils::log_error "systemd::enable_now requires at least one unit"
        return 1
    fi
    systemd::__ctl enable --now "$@"
}

systemd::enable() {
  # Purpose: Run 'systemctl enable' for a unit.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 1 ]]; then
        utils::log_error "systemd::enable requires at least one unit"
        return 1
    fi
    systemd::__ctl enable "$@"
}

systemd::disable_now() {
  # Purpose: Run 'systemctl disable-now' for a unit.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 1 ]]; then
        utils::log_error "systemd::disable_now requires at least one unit"
        return 1
    fi
    systemd::__ctl disable --now "$@"
}

systemd::start() {
  # Purpose: Run 'systemctl start' for a unit.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 1 ]]; then
        utils::log_error "systemd::start requires at least one unit"
        return 1
    fi
    systemd::__ctl start "$@"
}

systemd::stop() {
  # Purpose: Run 'systemctl stop' for a unit.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 1 ]]; then
        utils::log_error "systemd::stop requires at least one unit"
        return 1
    fi
    systemd::__ctl stop "$@"
}

systemd::restart() {
  # Purpose: Restart a systemd unit (systemctl restart).
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ $# -lt 1 ]]; then
        utils::log_error "systemd::restart requires at least one unit"
        return 1
    fi
    systemd::__ctl restart "$@"
}

systemd::is_active() {
  # Purpose: Query whether a systemd unit is active (read-only).
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local unit="$1"
    systemd::__query is-active --quiet "${unit}"
}

systemd::is_enabled() {
  # Purpose: Query whether a systemd unit is enabled (read-only).
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local unit="$1"
    systemd::__query is-enabled --quiet "${unit}"
}
