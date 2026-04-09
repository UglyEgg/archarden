# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# HTTP helpers (curl wrapper).
#
# Goals:
# - Centralize common curl flags/timeouts
# - Capture status/body reliably without aborting archarden under `set -e`
# - Provide a narrow DRY_RUN behavior (log only; no network)

declare -g HTTP_LAST_STATUS="" HTTP_LAST_BODY=""

http::request() {
  # Purpose: Perform an HTTP request via curl, capturing status/body and honoring DRY_RUN.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Usage: http::request <METHOD> <URL> [BODY] [CURL_ARGS...]
  #
  # Behavior:
  # - On success (HTTP < 400): prints body and returns 0
  # - On HTTP error (>= 400): returns 22
  # - On curl transport error: returns curl's exit code
  # - Always sets HTTP_LAST_STATUS and HTTP_LAST_BODY
  #
  # Note: callers may pass -H, -u, --resolve, -k, etc via CURL_ARGS.

    local method="$1" url="$2" body="${3:-}"
    shift 3 || true

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        utils::log_info "DRY_RUN: http ${method} ${url}"
        HTTP_LAST_STATUS="200"
        HTTP_LAST_BODY=""
        return 0
    fi

    local tmp status rc
    tmp="$(mktemp)"

    local -a curl_args=(
        -sS
        --max-time 15
        --connect-timeout 3
        -X "${method}"
        -o "${tmp}"
        -w '%{http_code}'
    )

    # Allow callers to override defaults by passing their own args.
    curl_args+=("$@")

    if [[ "${method}" != "GET" && -n "${body}" ]]; then
        curl_args+=( -d "${body}" )
    fi

    status="$(curl "${curl_args[@]}" "${url}")"
    rc=$?

    HTTP_LAST_STATUS="${status}"
    HTTP_LAST_BODY="$(cat "${tmp}" 2>/dev/null || true)"
    rm -f "${tmp}"

    if [[ ${rc} -ne 0 ]]; then
        return ${rc}
    fi

    if [[ -z "${status}" || "${status}" == "000" ]]; then
        return 1
    fi

    if [[ "${status}" =~ ^[0-9]+$ ]] && (( status >= 400 )); then
        return 22
    fi

    printf '%s' "${HTTP_LAST_BODY}"
}

http::http_code() {
  # Purpose: Probe a URL and print only the HTTP status code, honoring DRY_RUN.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Usage: http::http_code <URL> [CURL_ARGS...]
  # Prints the HTTP code (or 000 on transport failure) and returns 0 if curl ran.
    local url="$1"
    shift || true

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        utils::log_info "DRY_RUN: http_code ${url}"
        echo "200"
        return 0
    fi

    curl -sS --max-time 5 --connect-timeout 2 -o /dev/null -w '%{http_code}' "$@" "${url}" 2>/dev/null || echo "000"
}
