# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck shell=bash

ntfy::podmin_config_dir() {
   local podmin_home
   podmin_home="${PODMAN_HOME:-$(getent passwd "${PODMAN_USER}" | cut -d: -f6)}"
   [[ -n "${podmin_home}" ]] || podmin_home="/home/${PODMAN_USER}"
   printf '%s/.config/archarden/ntfy
' "${podmin_home}"
}

ntfy::server_config_path() {
   printf '%s/server.yml
' "$(ntfy::podmin_config_dir)"
}

ntfy::base_url() {
   if [[ -n "${NTFY_PUBLIC_HOST:-}" ]]; then
       printf 'https://%s
' "${NTFY_PUBLIC_HOST}"
   else
       printf 'http://127.0.0.1:2586
'
   fi
}

ntfy::wait_ready() {
   local base_url="$1"
   http::request GET "${base_url%/}/v1/health" '' --max-time 8 --connect-timeout 3 >/dev/null 2>&1
}

ntfy::send_message() {
   local base_url="$1" topic="$2" title="$3" message="$4" priority="${5:-3}" token="${6:-}" user="${7:-}" pass="${8:-}"
   local url="${base_url%/}/${topic}"
   local -a args=( --max-time 12 --connect-timeout 4 -H "Title: ${title}" -H "Priority: ${priority}" )
   if [[ -n "${token}" ]]; then
       args+=( -H "Authorization: Bearer ${token}" )
   elif [[ -n "${user}" ]]; then
       args+=( -u "${user}:${pass}" )
   fi
   curl -fsS -X POST "${url}" "${args[@]}" -d "${message}" >/dev/null
}

ntfy::hash_password() {
   local password="$1"
   local out=""
   local i
   local image="docker.io/binwiederhier/ntfy:latest"
   local err_file

   if [[ ${DRY_RUN:-0} -eq 1 ]]; then
       printf '$2a$10$dryrundryrundryrundryrundryrundryrundryrundryru\n'
       return 0
   fi

   err_file="$(mktemp)"

   for ((i=0; i<5; i++)); do
       if out="$(
           printf '%s\n%s\n' "${password}" "${password}" | \
           podman run --rm -i "${image}" user hash 2>"${err_file}" | tr -d '\n'
       )" && [[ -n "${out}" ]]; then
           rm -f "${err_file}"
           printf '%s\n' "${out}"
           return 0
       fi
       sleep 1
   done

   utils::log_error "ntfy password hash generation failed after retries."
   if [[ -s "${err_file}" ]]; then
       while IFS= read -r line; do
           utils::log_error "ntfy hash stderr: ${line}"
       done < "${err_file}"
   fi
   rm -f "${err_file}"
   return 1
}

ntfy::write_server_config() {
   local base_url="$1" admin_user="$2" admin_hash="$3" publish_user="$4" publish_hash="$5" topic="$6" token="$7"
   local podmin_dir server_path tmp owner_group
   podmin_dir="$(ntfy::podmin_config_dir)"
   server_path="$(ntfy::server_config_path)"
   fs::ensure_dir "${podmin_dir}" 0750 "${PODMAN_USER}" "${PODMAN_USER}"
   tmp="$(mktemp)"
   cat >"${tmp}" <<EOF2
base-url: "${base_url}"
listen-http: ":80"
behind-proxy: $([[ "${base_url}" == https://* ]] && echo true || echo false)
cache-file: "/var/cache/ntfy/cache.db"
attachment-cache-dir: "/var/cache/ntfy/attachments"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
web-root: disable
enable-login: true
require-login: true
enable-signup: false
auth-users:
 - "${admin_user}:${admin_hash}:admin"
 - "${publish_user}:${publish_hash}:user"
auth-access:
 - "${publish_user}:${topic}:wo"
auth-tokens:
 - "${publish_user}:${token}:Archarden publisher"
EOF2
   install -D -m 0640 -o "${PODMAN_USER}" -g "${PODMAN_USER}" "${tmp}" "${server_path}"
   rm -f "${tmp}"
}

ntfy::write_env() {
   local url="$1" topic="$2" token="${3:-}" user="${4:-}" pass="${5:-}"
   local env_path="/etc/archarden/notify.env" tmp
   fs::ensure_dir /etc/archarden 0755 root root
   tmp="$(mktemp)"
   ( umask 077; printf 'NOTIFY_BACKEND=ntfy
NTFY_URL=%s
NTFY_TOPIC=%s
NTFY_EXTERNAL_URL=%s
' "${url}" "${topic}" "${url}" >"${tmp}" )
   if [[ -n "${token}" ]]; then printf 'NTFY_TOKEN=%s
' "${token}" >>"${tmp}"; fi
   if [[ -n "${user}" ]]; then printf 'NTFY_USER=%s
NTFY_PASS=%s
' "${user}" "${pass}" >>"${tmp}"; fi
   printf 'NTFY_PRIORITY=%s
' "${NTFY_PRIORITY:-5}" >>"${tmp}"
   install -D -m 0600 -o root -g root "${tmp}" "${env_path}"
   rm -f "${tmp}"
}

ntfy::ensure_runtime_config() {
   local admin_user admin_pass publish_user publish_pass topic token base_url admin_hash publish_hash
   admin_user="$(secrets::ensure_ntfy_admin_user)" || return 1
   admin_pass="$(secrets::ensure_ntfy_admin_pass)" || return 1
   publish_user="$(secrets::ensure_ntfy_publish_user)" || return 1
   publish_pass="$(secrets::ensure_ntfy_publish_pass)" || return 1
   topic="$(secrets::ensure_ntfy_topic)" || return 1
   token="$(secrets::ensure_ntfy_token)" || return 1
   base_url="$(ntfy::base_url)"
   admin_hash="$(ntfy::hash_password "${admin_pass}")" || return 1
   publish_hash="$(ntfy::hash_password "${publish_pass}")" || return 1
   ntfy::write_server_config "${base_url}" "${admin_user}" "${admin_hash}" "${publish_user}" "${publish_hash}" "${topic}" "${token}" || return 1
   ntfy::write_env "${base_url}" "${topic}" "${token}"
}

ntfy::restart_service() {
   if [[ ${DRY_RUN:-0} -eq 1 ]]; then
       utils::log_info "[DRY-RUN] Would restart ntfy.service"
       return 0
   fi
   podman_runtime::podmin_systemctl restart ntfy.service || return 1
   local i
   for ((i=0; i<40; i++)); do
       if ntfy::wait_ready "http://127.0.0.1:2586"; then
           return 0
       fi
       sleep 0.5
   done
   return 1
}
