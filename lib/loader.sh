# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (c) 2025 Richard Majewski

source_libs() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/utils.sh
    source "${script_dir}/utils.sh"
    # shellcheck source=lib/backup.sh
    source "${script_dir}/backup.sh"
    # shellcheck source=lib/system.sh
    source "${script_dir}/system.sh"
}
