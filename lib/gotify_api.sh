# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# Gotify API helpers (curl/jq, readiness, token/user operations).

gotify_api::api_base_url() {
  # Purpose: Api base url.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local host="$1"
    printf 'https://%s' "${host}"
}

gotify_api::internal_base_url() {
  # Purpose: Internal base url for host->container access.
  # Inputs: None.
  # Outputs: Prints base url or empty.
    local ip=""

    if command -v runuser >/dev/null 2>&1; then
        ip="$(runuser -u podmin -- bash -lc 'cd ~ >/dev/null 2>&1 || true; podman inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" gotify 2>/dev/null' || true)"
    fi

    if [[ -n "${ip}" ]]; then
        printf 'http://%s:80' "${ip}"
        return 0
    fi

    return 1
}

gotify_api::__curl_args() {
  # Purpose: Curl args.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local host="$1"
    printf '%s\n' \
        -k \
        --max-time 12 \
        --connect-timeout 4 \
        --resolve "${host}:443:127.0.0.1"
}

gotify_api::curl_api() {
  # Purpose: Curl api.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # args: HOST URL_PATH
    local host="$1" path="$2"
    local -a args
    mapfile -t args < <(gotify_api::__curl_args "${host}")
    http::request GET "https://${host}${path}" '' "${args[@]}"
}

gotify_api::wait_ready() {
  # Purpose: Wait ready. (network)
  # Inputs: None.
  # Outputs: Return 0 when Gotify is reachable on an internal path or proxied host.
    if [[ -z "${GOTIFY_PUBLIC_HOST:-}" ]]; then
        return 1
    fi

    local host="${GOTIFY_PUBLIC_HOST}" i base
    for ((i=1; i<=40; i++)); do
        base="$(gotify_api::internal_base_url 2>/dev/null || true)"
        if [[ -n "${base}" ]] && curl -fsS --max-time 3 --connect-timeout 2 "${base}/health" >/dev/null 2>&1; then
            return 0
        fi
        if http::request GET "https://${host}/health" '' --max-time 3 --connect-timeout 2 --resolve "${host}:443:127.0.0.1" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

gotify_api::proxy_health_ok() {
  # Purpose: Check Gotify health via the public (proxied) URL.
  # Inputs: None.
  # Outputs: Return 0 if reachable; non-zero otherwise.
    if [[ -z "${GOTIFY_PUBLIC_HOST:-}" ]]; then
        return 1
    fi
    local host="${GOTIFY_PUBLIC_HOST}"
    http::request GET "https://${host}/health" '' --max-time 5 --connect-timeout 3 --resolve "${host}:443:127.0.0.1" >/dev/null 2>&1
}

gotify_api::basic_auth_ok() {
  # Purpose: Basic auth ok.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local user="$1" pass="$2"

    local base=""
    base="$(gotify_api::internal_base_url 2>/dev/null || true)"
    if [[ -n "${base}" ]]; then
        http::request GET "${base}/current/user" '' --max-time 8 --connect-timeout 3 -u "${user}:${pass}" >/dev/null 2>&1
        return $?
    fi

    local host="${GOTIFY_PUBLIC_HOST}"
    http::request GET "https://${host}/current/user" '' --max-time 8 --connect-timeout 3 --resolve "${host}:443:127.0.0.1" -u "${user}:${pass}" >/dev/null 2>&1
}

gotify_api::set_user_password_via_api() {
  # Purpose: Set user password via api.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local user="$1" old_pass="$2" new_pass="$3"
    local base=""
    base="$(gotify_api::internal_base_url 2>/dev/null || true)"
    local payload
    payload=$(jq -nc --arg pass "${new_pass}" '{pass:$pass}')
    if [[ -n "${base}" ]]; then
        http::request POST "${base}/current/user/password" "${payload}" --max-time 12 --connect-timeout 4 -u "${user}:${old_pass}" -H 'Content-Type: application/json' >/dev/null 2>&1
        return $?
    fi

    local host="${GOTIFY_PUBLIC_HOST}"
    http::request POST "https://${host}/current/user/password" "${payload}" --max-time 12 --connect-timeout 4 --resolve "${host}:443:127.0.0.1" -u "${user}:${old_pass}" -H 'Content-Type: application/json' >/dev/null 2>&1
}

gotify_api::get_or_create_app_token() {
  # Purpose: Get or create app token.
  # Inputs: Positional parameters $1..$2.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local admin_pass="$1"
    local base=""
    base="$(gotify_api::internal_base_url 2>/dev/null || true)"
    local apps token

    if [[ -n "${base}" ]]; then
        apps=$(http::request GET "${base}/application" '' --max-time 12 --connect-timeout 4 -u "admin:${admin_pass}" | jq -r '.[] | "\(.name)\t\(.token)"' || true)
    else
        local host="${GOTIFY_PUBLIC_HOST}"
        apps=$(http::request GET "https://${host}/application" '' --max-time 12 --connect-timeout 4 --resolve "${host}:443:127.0.0.1" -u "admin:${admin_pass}" | jq -r '.[] | "\(.name)\t\(.token)"' || true)
    fi
    token=$(echo "${apps}" | awk -F '\t' '$1=="archarden"{print $2}' | head -n1)
    if [[ -n "${token}" ]]; then
        echo "${token}"
        return 0
    fi

    local payload
    payload='{"name":"archarden","description":"archarden system notifications"}'
    if [[ -n "${base}" ]]; then
        token=$(http::request POST "${base}/application" "${payload}" --max-time 12 --connect-timeout 4 -u "admin:${admin_pass}" -H 'Content-Type: application/json' | jq -r '.token' || true)
    else
        local host="${GOTIFY_PUBLIC_HOST}"
        token=$(http::request POST "https://${host}/application" "${payload}" --max-time 12 --connect-timeout 4 --resolve "${host}:443:127.0.0.1" -u "admin:${admin_pass}" -H 'Content-Type: application/json' | jq -r '.token' || true)
    fi
    if [[ -z "${token}" || "${token}" == "null" ]]; then
        return 1
    fi
    echo "${token}"
}
