# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

notify::_ensure_lib_dir() {
    local lib_dir=/usr/lib/archarden
    fs::ensure_dir "${lib_dir}" 0750
}

notify::install_notify_script() {
    local lib_dir=/usr/lib/archarden
    notify::_ensure_lib_dir
    utils::install_template_root_file "templates/notify/notify_send.sh.tmpl" "${lib_dir}/notify_send.sh" 0750 root root
}
