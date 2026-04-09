#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Secret helpers.
# - Secrets are stored under STATE_DIR (default: /var/lib/archarden).
# - Files are mode 0600 root:root.
# - In DRY_RUN mode, deterministic placeholder values are returned and no files are written.

secrets::dir() {
  # Purpose: Dir.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    echo "${STATE_DIR}/secrets"
}

secrets::path() {
  # Purpose: Path.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local key="$1"
    echo "$(secrets::dir)/${key}"
}

secrets::ensure_dir() {
  # Purpose: Ensure dir.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    fs::ensure_dir "$(secrets::dir)" 0700 root root
}

secrets::read() {
  # Purpose: Read.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local key="$1"
    local path
    path="$(secrets::path "${key}")"
    [[ -f "${path}" ]] || return 1
    cat "${path}"
}

secrets::write() {
  # Purpose: Write the requested state.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local key="$1" value="$2"
    local path tmp
    path="$(secrets::path "${key}")"

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would write secret ${key} to ${path} (0600 root:root)."
        return 0
    fi

    secrets::ensure_dir

    tmp=$(mktemp)
    ( umask 077; printf '%s' "${value}" >"${tmp}" )
    install -D -m 0600 -o root -g root "${tmp}" "${path}"
    rm -f "${tmp}"
}

secrets::generate_alnum() {
  # Purpose: Generate alnum.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local length="$1"

    # Defensive: length must be a positive integer.
    if [[ -z "${length}" || ! "${length}" =~ ^[0-9]+$ || "${length}" -le 0 ]]; then
        length=32
    fi

    # Generate a fixed-length, alnum-only secret.
    #
    # NOTE: The top-level entrypoint runs with `set -o pipefail`. A naive pipeline like:
    #   tr -dc ... </dev/urandom | head -c N
    # will routinely cause `tr` to exit with SIGPIPE when `head` terminates early,
    # which then propagates as a non-zero status under `pipefail`.
    #
    # Prefer a non-pipeline generator when available.
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${length}" <<'PY'
import os, re, sys

length = int(sys.argv[1]) if len(sys.argv) > 1 else 32
alphabet = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

out = bytearray()
while len(out) < length:
    # Pull more entropy than we need to keep the loop tight.
    chunk = os.urandom(max(256, length * 2))
    for b in chunk:
        if b in alphabet:
            out.append(b)
            if len(out) >= length:
                break

sys.stdout.write(out.decode("ascii"))
PY
        return 0
    fi

    # Fallback: temporarily disable pipefail and validate output length.
    local value
    set +o pipefail
    value="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}" 2>/dev/null || true)"
    set -o pipefail
    printf '%s' "${value}"
}

secrets::ensure_alnum() {
  # Purpose: Ensure alnum.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local key="$1" length="$2" placeholder="$3"

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo "${placeholder}"
        return 0
    fi

    if secrets::read "${key}" >/dev/null 2>&1; then
        secrets::read "${key}"
        return 0
    fi

    local value
    value="$(secrets::generate_alnum "${length}")" || {
        printf '%s\n' "[ERROR] Failed to generate secret ${key}" >&2
        return 1
    }
    if [[ -z "${value}" ]]; then
        printf '%s\n' "[ERROR] Generated secret ${key} was empty" >&2
        return 1
    fi
    secrets::write "${key}" "${value}"
    echo "${value}"
}


secrets::ensure_npm_admin_email() {
  # Purpose: Ensure npm admin email.
    local fallback="${NPM_ADMIN_EMAIL:-${LE_EMAIL:-}}"

    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        if [[ -n "${fallback}" ]]; then
            echo "${fallback}"
            return 0
        fi
        utils::log_error "NPM admin email is required. Provide --npm-admin-email or --le-email."
        return 1
    fi

    if secrets::read "npm_admin_email" >/dev/null 2>&1; then
        local existing
        existing="$(secrets::read "npm_admin_email")"
        if [[ -z "${existing}" || "${existing}" == *.internal || "${existing}" == *.local ]]; then
            if [[ -n "${fallback}" ]]; then
                secrets::write "npm_admin_email" "${fallback}"
                echo "${fallback}"
                return 0
            fi
            utils::log_error "Persisted NPM admin email is invalid ('${existing}'). Provide --npm-admin-email or --le-email."
            return 1
        fi
        echo "${existing}"
        return 0
    fi

    if [[ -z "${fallback}" ]]; then
        utils::log_error "NPM admin email is required. Provide --npm-admin-email or --le-email."
        return 1
    fi
    if [[ "${fallback}" == *.internal || "${fallback}" == *.local ]]; then
        utils::log_error "Refusing invalid NPM admin email '${fallback}'. Provide a real email address via --npm-admin-email or --le-email."
        return 1
    fi

    secrets::write "npm_admin_email" "${fallback}"
    echo "${fallback}"
}

secrets::ensure_npm_admin_pass() {
  # Purpose: Ensure npm admin pass.
    secrets::ensure_alnum "npm_admin_pass" 48 "DRYRUN_NPM_ADMIN_PASS"
}





secrets::ensure_kuma_admin_user() {
  # Purpose: Ensure uptime kuma admin user.
    local fallback="${KUMA_ADMIN_USER:-admin}"
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo "${fallback}"
        return 0
    fi
    if secrets::read "kuma_admin_user" >/dev/null 2>&1; then
        secrets::read "kuma_admin_user"
        return 0
    fi
    secrets::write "kuma_admin_user" "${fallback}"
    echo "${fallback}"
}

secrets::ensure_kuma_admin_pass() {
  # Purpose: Ensure uptime kuma admin pass.
    secrets::ensure_alnum "kuma_admin_pass" 48 "DRYRUN_KUMA_ADMIN_PASS"
}


secrets::ensure_ntfy_admin_user() {
  # Purpose: Ensure ntfy admin user.
    local fallback="${NTFY_ADMIN_USER:-${USER_NAME:-admin}}"
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo "${fallback}"
        return 0
    fi
    if secrets::read "ntfy_admin_user" >/dev/null 2>&1; then
        secrets::read "ntfy_admin_user"
        return 0
    fi
    secrets::write "ntfy_admin_user" "${fallback}"
    echo "${fallback}"
}

secrets::ensure_ntfy_admin_pass() {
  # Purpose: Ensure ntfy admin password.
    secrets::ensure_alnum "ntfy_admin_pass" 32 "DRYRUN_NTFY_ADMIN_PASS"
}

secrets::ensure_ntfy_publish_user() {
  # Purpose: Ensure ntfy publisher user.
    local fallback="${NTFY_PUBLISH_USER:-archarden-notify}"
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo "${fallback}"
        return 0
    fi
    if secrets::read "ntfy_publish_user" >/dev/null 2>&1; then
        secrets::read "ntfy_publish_user"
        return 0
    fi
    secrets::write "ntfy_publish_user" "${fallback}"
    echo "${fallback}"
}

secrets::ensure_ntfy_publish_pass() {
  # Purpose: Ensure ntfy publisher password.
    secrets::ensure_alnum "ntfy_publish_pass" 32 "DRYRUN_NTFY_PUBLISH_PASS"
}

secrets::ensure_ntfy_topic() {
  # Purpose: Ensure randomized ntfy topic.
    local prefix="${NTFY_TOPIC_PREFIX:-archarden}"
    local suffix
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo "${prefix}-DRYRUNNTFYTOPIC"
        return 0
    fi
    if secrets::read "ntfy_topic" >/dev/null 2>&1; then
        secrets::read "ntfy_topic"
        return 0
    fi
    suffix="$(secrets::generate_alnum 20 | tr '[:upper:]' '[:lower:]')"
    secrets::write "ntfy_topic" "${prefix}-${suffix}"
    echo "${prefix}-${suffix}"
}

secrets::ensure_ntfy_token() {
  # Purpose: Ensure ntfy publisher token.
    local suffix
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
        echo "tk_dryrunntfytokendryrunntfyt"
        return 0
    fi
    if secrets::read "ntfy_token" >/dev/null 2>&1; then
        secrets::read "ntfy_token"
        return 0
    fi
    suffix="$(secrets::generate_alnum 29 | tr '[:upper:]' '[:lower:]')"
    secrets::write "ntfy_token" "tk_${suffix}"
    echo "tk_${suffix}"
}
