# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Install helpers for Gotify-related scripts.

gotify::_ensure_lib_dir() {
  # Purpose: Ensure lib dir.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local lib_dir=/usr/lib/archarden
    fs::ensure_dir "${lib_dir}" 0750
}

gotify::install_notify_script() {
  # Purpose: Install notify script.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local lib_dir=/usr/lib/archarden
    gotify::_ensure_lib_dir

    utils::install_template_root_file "templates/gotify/gotify_send.sh.tmpl" "${lib_dir}/gotify_send.sh" 0750 root root
}
