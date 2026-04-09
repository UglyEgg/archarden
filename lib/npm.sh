# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# NPM API helpers.
#
# IMPORTANT: This library is sourced under `set -euo pipefail`.
# All network calls must be guarded so HTTP/connection failures do not
# abort the entire archarden run unless the caller explicitly chooses to exit.

declare -g NPM_LAST_STATUS="" NPM_LAST_BODY=""

npm::base_url() {
  # Purpose: Base url.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # NPM admin API is published to loopback only; WireGuard/browser access is provided
  # via a root-owned systemd socket proxy.
    echo "http://127.0.0.1:${NPM_ADMIN_BACKEND_PORT:-${NPM_ADMIN_PORT}}"
}


npm::_request() {
  # Purpose: Request.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Usage: npm::_request <METHOD> <PATH> [TOKEN] [JSON_BODY]
  # On success, prints response body.
  # On HTTP error (>=400) returns 22 and sets NPM_LAST_STATUS/NPM_LAST_BODY.
  # On transport error returns curl's exit code.

    local method="$1" path="$2" token="${3:-}" body="${4:-}"
    local base url status rc

    base="$(npm::base_url)"
    url="${base}${path}"

    local -a curl_args=(
        -H 'Content-Type: application/json'
    )

    if [[ -n "${token}" ]]; then
        curl_args+=( -H "Authorization: Bearer ${token}" )
    fi

    # http::request captures status/body and returns 22 on HTTP>=400.
    http::request "${method}" "${url}" "${body}" "${curl_args[@]}" >/dev/null 2>&1
    rc=$?
    status="${HTTP_LAST_STATUS}"

    NPM_LAST_STATUS="${status}"
    NPM_LAST_BODY="${HTTP_LAST_BODY}"

    if [[ ${rc} -ne 0 ]]; then
        return ${rc}
    fi

    printf '%s' "${NPM_LAST_BODY}"
}

npm::error_brief() {
  # Purpose: Error brief.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local body="${NPM_LAST_BODY:-}"
    body="${body//$'\n'/ }"
    if [[ ${#body} -gt 400 ]]; then
        body="${body:0:400}[truncated]"
    fi
    echo "status=${NPM_LAST_STATUS:-unknown} body=${body:-<empty>}"
}


npm::wait_ready() {
  # Purpose: Wait until the backend is ready enough for auth/bootstrap.
    local base attempts i code
    base="$(npm::base_url)"
    attempts="${1:-180}"
    for ((i=1; i<=attempts; i++)); do
        code="$(http::http_code "${base}/api/")"
        case "${code}" in
            200|400|401|403|404|405)
                return 0
                ;;
        esac
        sleep 2
    done
    return 1
}

npm::get_token() {
  # Purpose: Get token.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local identity="$1" secret="$2"
    local payload resp token

    payload="$(jq -nc --arg identity "${identity}" --arg secret "${secret}" '{identity:$identity, secret:$secret}')"

    if ! resp="$(npm::_request POST '/api/tokens' '' "${payload}")"; then
        return 1
    fi

    token="$(echo "${resp}" | jq -r '.token // .result.token // empty' 2>/dev/null || true)"
    [[ -n "${token}" ]] || return 1
    printf '%s' "${token}"
}

npm::api_get() {
  # Purpose: Api get.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local path="$1" token="$2"
    npm::_request GET "${path}" "${token}" ''
}

npm::api_put() {
  # Purpose: Api put.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local path="$1" token="$2" payload="$3"
    npm::_request PUT "${path}" "${token}" "${payload}"
}

npm::api_post() {
  # Purpose: Api post.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local path="$1" token="$2" body="$3"
    npm::_request POST "${path}" "${token}" "${body}"
}

npm::find_admin_user_id() {
  # Purpose: Find admin user id.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1"
    local users id

    if ! users="$(npm::api_get '/api/users' "${token}" 2>/dev/null)"; then
        echo "1"
        return 0
    fi

    id="$(echo "${users}" | jq -r '.[] | select(.roles and (.roles | index("admin"))) | .id' 2>/dev/null | head -n 1 || true)"
    [[ -n "${id}" ]] || id="1"
    printf '%s' "${id}"
}

npm::update_admin_email() {
  # Purpose: Update admin email.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1" user_id="$2" new_email="$3"

    local user name nickname is_disabled roles payload
    user="$(npm::api_get "/api/users/${user_id}" "${token}" 2>/dev/null || true)"

    name="$(echo "${user}" | jq -r '.name // "Administrator"' 2>/dev/null || true)"
    nickname="$(echo "${user}" | jq -r '.nickname // "Admin"' 2>/dev/null || true)"
    is_disabled="$(echo "${user}" | jq -r '.is_disabled // false' 2>/dev/null || true)"
    roles="$(echo "${user}" | jq -c '.roles // ["admin"]' 2>/dev/null || echo '["admin"]')"

    payload="$(jq -nc \
        --arg name "${name}" \
        --arg nickname "${nickname}" \
        --arg email "${new_email}" \
        --argjson is_disabled "${is_disabled}" \
        --argjson roles "${roles}" \
        '{name:$name,nickname:$nickname,email:$email,roles:$roles,is_disabled:$is_disabled}')"

    if ! npm::api_put "/api/users/${user_id}" "${token}" "${payload}" >/dev/null; then
        return 1
    fi
    return 0
}


npm::set_admin_password() {
  # Purpose: Set admin password.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1" user_id="$2" current_pw="$3" new_pw="$4"

    local payload
    if [[ -n "${current_pw}" ]]; then
        payload="$(jq -nc --arg type 'password' --arg current "${current_pw}" --arg secret "${new_pw}" '{type:$type,current:$current,secret:$secret}')"
    else
        payload="$(jq -nc --arg type 'password' --arg secret "${new_pw}" '{type:$type,secret:$secret}')"
    fi

    if ! npm::api_put "/api/users/${user_id}/auth" "${token}" "${payload}" >/dev/null; then
        return 1
    fi
    return 0
}


npm::list_proxy_hosts() {
  # Purpose: List proxy hosts.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1"
    npm::api_get '/api/nginx/proxy-hosts' "${token}"
}

npm::find_proxy_host_id_for_domain() {
  # Purpose: Find proxy host id for domain.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1" domain="$2"
    npm::list_proxy_hosts "${token}" | jq -r --arg d "${domain}" '.[] | select((.domain_names // []) | index($d)) | .id' | head -n1
}

npm::ensure_proxy_host() {
  # Purpose: Ensure proxy host.
  # Inputs: Positional parameters $1..$6.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1" domain="$2" forward_host="$3" forward_port="$4" certificate_id="$5" force_ssl="$6"

    local payload
    payload=$(jq -n \
        --argjson domain_names "[\"${domain}\"]" \
        --arg forward_host "${forward_host}" \
        --argjson forward_port "${forward_port}" \
        --argjson certificate_id "${certificate_id}" \
        --argjson ssl_forced "${force_ssl}" \
        '{
            domain_names: $domain_names,
            forward_scheme: "http",
            forward_host: $forward_host,
            forward_port: $forward_port,
            access_list_id: 0,
            certificate_id: $certificate_id,
            ssl_forced: $ssl_forced,
            http2_support: true,
            hsts_enabled: true,
            hsts_subdomains: false,
            block_exploits: true,
            caching_enabled: false,
            allow_websocket_upgrade: true,
            enabled: true
        }')

    local existing_id
    existing_id="$(npm::find_proxy_host_id_for_domain "${token}" "${domain}" 2>/dev/null || true)"

    if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
        if ! npm::api_put "/api/nginx/proxy-hosts/${existing_id}" "${token}" "${payload}" >/dev/null; then
            return 1
        fi
        echo "${existing_id}"
        return 0
    fi

    local created
    if ! created="$(npm::api_post '/api/nginx/proxy-hosts' "${token}" "${payload}")"; then
        return 1
    fi

    echo "${created}" | jq -r '.id'
}

npm::list_certificates() {
  # Purpose: List certificates.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1"
    npm::api_get '/api/nginx/certificates' "${token}"
}

npm::find_certificate_id_for_domain() {
  # Purpose: Find certificate id for domain.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1" domain="$2"
    npm::list_certificates "${token}" | jq -r --arg d "${domain}" '.[] | select((.domain_names // []) | index($d)) | .id' | head -n1
}

npm::create_letsencrypt_certificate() {
  # Purpose: Create letsencrypt certificate.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1" domain="$2" email="$3"

    local payload
    payload=$(jq -n \
        --arg domain "${domain}" \
        --arg email "${email}" \
        '{
            provider: "letsencrypt",
            nice_name: $domain,
            domain_names: [$domain],
            meta: {
                letsencrypt_email: $email,
                letsencrypt_agree: true,
                dns_challenge: false
            }
        }')

    local resp
    if ! resp="$(npm::api_post '/api/nginx/certificates' "${token}" "${payload}")"; then
        return 1
    fi

    echo "${resp}" | jq -r '.id'
}

npm::ensure_letsencrypt_certificate() {
  # Purpose: Ensure letsencrypt certificate.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local token="$1" domain="$2" email="$3"

    local existing_id
    existing_id="$(npm::find_certificate_id_for_domain "${token}" "${domain}" 2>/dev/null || true)"
    if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
        echo "${existing_id}"
        return 0
    fi

    npm::create_letsencrypt_certificate "${token}" "${domain}" "${email}"
}


npm::bootstrap_or_verify_admin() {
  # Purpose: Ensure desired admin credentials exist for NPM.
    local desired_email="$1" desired_pass="$2"
    local had_email_secret=0 had_pass_secret=0
    local token admin_id default_email default_password

    secrets::read "npm_admin_email" >/dev/null 2>&1 && had_email_secret=1 || true
    secrets::read "npm_admin_pass" >/dev/null 2>&1 && had_pass_secret=1 || true

    if ! npm::wait_ready 180; then
        utils::log_error "NPM admin backend did not become auth-ready at $(npm::base_url)."
        return 1
    fi

    if npm::get_token "${desired_email}" "${desired_pass}" >/dev/null 2>&1; then
        return 0
    fi

    default_email="admin@example.com"
    default_password="changeme"
    # Older NPM releases seeded admin@example.com/changeme by default. Newer releases
    # (for example v2.13.0) removed the default initial user and expect operators to use
    # setup wizard or INITIAL_ADMIN_* env vars. Try the legacy bootstrap creds only as a
    # compatibility fallback after the desired seeded credentials fail.
    if token="$(npm::get_token "${default_email}" "${default_password}" 2>/dev/null)"; then
        admin_id="$(npm::find_admin_user_id "${token}")"
        npm::set_admin_password "${token}" "${admin_id}" "${default_password}" "${desired_pass}" >/dev/null || return 1
        npm::update_admin_email "${token}" "${admin_id}" "${desired_email}" >/dev/null || return 1
        npm::get_token "${desired_email}" "${desired_pass}" >/dev/null 2>&1 || return 1
        return 0
    fi

    if [[ ${had_email_secret} -eq 1 || ${had_pass_secret} -eq 1 ]]; then
        utils::log_error "Stored NPM admin credentials did not verify after the backend became ready, and default bootstrap credentials were rejected. Existing NPM state likely drifted or was changed manually."
    else
        utils::log_error "NPM admin backend is ready, but neither the desired seeded credentials nor the legacy default bootstrap credentials were accepted. On newer NPM releases this usually means INITIAL_ADMIN_* was not passed into the container start, or an existing data volume already contains different credentials."
    fi
    return 1
}
