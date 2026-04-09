# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash
{
    __notify_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${__notify_lib_dir}/notify_install.sh"
    source "${__notify_lib_dir}/notify_units.sh"
    unset __notify_lib_dir
}
