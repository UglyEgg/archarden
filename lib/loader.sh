# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

loader::source_libs() {
  # Purpose: Source libs.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/utils.sh
    source "${script_dir}/utils.sh"
    # shellcheck source=lib/pkg.sh
    source "${script_dir}/pkg.sh"
    # shellcheck source=lib/http.sh
    source "${script_dir}/http.sh"
    # shellcheck source=lib/fs.sh
    source "${script_dir}/fs.sh"
    # shellcheck source=lib/systemd.sh
    source "${script_dir}/systemd.sh"
    # shellcheck source=lib/secrets.sh
    source "${script_dir}/secrets.sh"
    # shellcheck source=lib/backup.sh
    source "${script_dir}/backup.sh"
    # shellcheck source=lib/fail2ban.sh
    source "${script_dir}/fail2ban.sh"
    # shellcheck source=lib/firewall.sh
    source "${script_dir}/firewall.sh"
    # shellcheck source=lib/system.sh
    source "${script_dir}/system.sh"
    # shellcheck source=lib/ssh.sh
    source "${script_dir}/ssh.sh"
    # shellcheck source=lib/npm.sh
    source "${script_dir}/npm.sh"
    # shellcheck source=lib/kuma.sh
    source "${script_dir}/kuma.sh"
    # shellcheck source=lib/ntfy.sh
    source "${script_dir}/ntfy.sh"
    # shellcheck source=lib/notify.sh
    source "${script_dir}/notify.sh"
    # shellcheck source=lib/creds.sh
    source "${script_dir}/creds.sh"
    # shellcheck source=lib/doctor.sh
    source "${script_dir}/doctor.sh"
}
