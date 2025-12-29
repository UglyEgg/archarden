# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

source_libs() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/utils.sh
    source "${script_dir}/utils.sh"
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
}
