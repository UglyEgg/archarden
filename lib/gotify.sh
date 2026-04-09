#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Minimal Gotify API helpers for Phase 2 operations.
# This library assumes curl + jq are available.

gotify::request() {
  # Purpose: Request.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # args: METHOD URL AUTH_HEADER(optional) JSON_PAYLOAD(optional)
    local method="$1" url="$2" auth_header="${3:-}" payload="${4:-}"

    local -a args=( -f )
    if [[ -n "${payload}" ]]; then
        args+=( -H 'Content-Type: application/json' )
    fi
    if [[ -n "${auth_header}" ]]; then
        args+=( -H "${auth_header}" )
    fi

    http::request "${method}" "${url}" "${payload}" "${args[@]}"
}

gotify::basic_auth_header() {
  # Purpose: Basic auth header.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local user="$1" pass="$2"
    # Basic base64 without trailing newline
    local token
    token="$(printf '%s:%s' "${user}" "${pass}" | base64 | tr -d '
')"
    printf 'Authorization: Basic %s' "${token}"
}

gotify::wait_ready() {
  # Purpose: Wait ready. (network)
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local base_url="$1"
    local attempts="${2:-60}"
    local i
    for ((i=1; i<=attempts; i++)); do
        if http::request GET "${base_url}/health" '' -f --max-time 3 >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

gotify::list_apps() {
  # Purpose: List apps.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local base_url="$1" auth="$2"
    gotify::request GET "${base_url}/application" "${auth}"
}

gotify::find_app_token() {
  # Purpose: Find app token.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # returns token for app name if present; empty otherwise
    local base_url="$1" auth="$2" app_name="$3"
    local apps token
    apps="$(gotify::list_apps "${base_url}" "${auth}")"
    token="$(echo "${apps}" | jq -r --arg n "${app_name}" '.[] | select(.name==$n) | .token' | head -n 1 || true)"
    printf '%s' "${token}"
}

gotify::create_app() {
  # Purpose: Create app.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # returns token from response
    local base_url="$1" auth="$2" app_name="$3"
    local payload
    payload="$(jq -nc --arg name "${app_name}" '{name:$name}')"
    gotify::request POST "${base_url}/application" "${auth}" "${payload}"
}

gotify::ensure_app_token() {
  # Purpose: Ensure app token.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local base_url="$1" auth="$2" app_name="$3"
    local token
    token="$(gotify::find_app_token "${base_url}" "${auth}" "${app_name}")"
    if [[ -n "${token}" && "${token}" != "null" ]]; then
        printf '%s' "${token}"
        return 0
    fi
    local resp
    resp="$(gotify::create_app "${base_url}" "${auth}" "${app_name}")"
    token="$(echo "${resp}" | jq -r '.token // empty' || true)"
    [[ -n "${token}" ]] || return 1
    printf '%s' "${token}"
}

gotify::send_message() {
  # Purpose: Send message.
  # Inputs: Positional parameters $1..$5.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local base_url="$1" token="$2" title="$3" message="$4" priority="${5:-5}"
    local payload
    payload="$(jq -nc --arg title "${title}" --arg message "${message}" --argjson priority "${priority}" '{title:$title,message:$message,priority:$priority}')"
    gotify::request POST "${base_url}/message?token=${token}" "" "${payload}" >/dev/null
}
