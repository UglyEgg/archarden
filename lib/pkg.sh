## SPDX-License-Identifier: GPL-3.0-or-later
## Copyright 2026 Richard Majewski

# Package management primitives (Arch/pacman).

pkg::read_list() {
  # Purpose: Read list.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local file="$1" optional="${2:-0}"
    if [[ ! -f "${file}" ]]; then
        if [[ "${optional}" -eq 1 ]]; then
            utils::log_warn "Optional package list not found: ${file}; skipping"
            return 0
        fi
        utils::log_error "Required package list not found: ${file}"
        exit 1
    fi

    grep -Ev '^[[:space:]]*(#|$)' "${file}"
}

pkg::is_installed() {
  # Purpose: Return success if a package is installed.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local pkg="$1"
    utils::require_cmd pacman "pacman is required to query installation state"
    pacman -Q "${pkg}" >/dev/null 2>&1
}

pkg::replace_if_installed() {
  # Purpose: Replace a package only if the old package is present (safe idempotent replace).
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local current="$1" replacement="$2"
    if pkg::is_installed "${current}"; then
        pkg::replace "${current}" "${replacement}"
    fi
}

pkg::replace() {
  # Purpose: Replace.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local current="$1" replacement="$2"
    utils::require_cmd pacman "pacman is required to replace packages"

    utils::log_info "Replacing installed package ${current} with ${replacement}"

    # Some "replacement" packages can be installed alongside the original without
    # causing pacman to error, but the system will continue using the original
    # binaries (e.g., iptables backend package choices). Prefer an explicit remove+install
    # to ensure the replacement actually takes effect.
    if utils::run_cmd "pacman -S --noconfirm --needed ${replacement}"; then
        if pkg::is_installed "${current}"; then
            utils::log_info "${current} remains installed; removing it to activate ${replacement}"

            # pacman -Q is authoritative for installed state, but we still guard the
            # removal to avoid aborting on benign "target not found" outcomes that
            # can occur when replacement packages provide the tooling without the
            # original package being present as a real local package record.
            if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
                utils::log_info "DRY_RUN: pacman -Rdd --noconfirm -- ${current}"
            else
                local rm_out
                rm_out=$(pacman -Rdd --noconfirm -- "${current}" 2>&1) || {
                    if grep -qi "target not found" <<<"${rm_out}"; then
                        utils::log_warn "Package ${current} not found during removal; continuing"
                    else
                        utils::log_error "Failed to remove ${current}: ${rm_out}"
                        return 1
                    fi
                }
            fi

            utils::run_cmd "pacman -S --noconfirm --needed ${replacement}"
        fi
        return 0
    fi

    utils::log_warn "Direct install failed; retrying by removing ${current} first"
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        utils::log_info "DRY_RUN: pacman -Rdd --noconfirm -- ${current}"
    else
        local rm_out
        rm_out=$(pacman -Rdd --noconfirm -- "${current}" 2>&1) || {
            if grep -qi "target not found" <<<"${rm_out}"; then
                utils::log_warn "Package ${current} not found during removal; continuing"
            else
                utils::log_error "Failed to remove ${current}: ${rm_out}"
                return 1
            fi
        }
    fi
    utils::run_cmd "pacman -S --noconfirm --needed ${replacement}"
}

pkg::requested() {
  # Purpose: Requested.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local target="$1" packages_var="$2"
    local -n packages_ref=${packages_var}
    local pkg
    for pkg in "${packages_ref[@]}"; do
        if [[ "${pkg}" == "${target}" ]]; then
            return 0
        fi
    done
    return 1
}

pkg::apply_replacements() {
  # Purpose: Apply replacements.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local packages_var="$1" replacements_file="$2"
    local -n packages_ref=${packages_var}

    local -a replacements=()
    while IFS= read -r line; do
        replacements+=("${line}")
    done < <(pkg::read_list "${replacements_file}" 1)

    if [[ ${#replacements[@]} -eq 0 ]]; then
        return 0
    fi

    local entry current replacement
    for entry in "${replacements[@]}"; do
        read -r current replacement <<<"${entry}"
        if [[ -z "${current}" || -z "${replacement}" ]]; then
            utils::log_warn "Skipping malformed replacement entry: ${entry}"
            continue
        fi
        if ! pkg::requested "${replacement}" "${packages_var}"; then
            continue
        fi
        pkg::replace_if_installed "${current}" "${replacement}"
    done
}

pkg::install_list() {
  # Purpose: Install a list of packages via pacman (idempotent where possible), honoring DRY_RUN.
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local -a pkgs=("$@")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        utils::log_warn "No packages requested; skipping package installation"
        return 0
    fi
    utils::require_cmd pacman "pacman is required to install packages"

    utils::log_info "Updating system and installing packages: ${pkgs[*]}"
    utils::run_cmd "pacman -Syu --noconfirm ${pkgs[*]}"
}
