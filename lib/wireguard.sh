# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright 2026 Richard Majewski
# shellcheck shell=bash

# WireGuard provisioning, peer generation, and export helpers extracted from lib/steps.sh.

wireguard::server_shortname() {
  # Purpose: Server shortname.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Prefer the requested hostname (if provided) so client names are stable across the run.
    local hn="${SYSTEM_HOSTNAME:-}"
    if [[ -z "${hn}" ]]; then
        hn=$(hostname -s 2>/dev/null || true)
    fi
    hn="${hn%%.*}"
    if [[ -z "${hn}" ]]; then
        hn="server"
    fi
    echo "${hn}"
}

wireguard::_require_ipv4_24() {
  # Purpose: Require ipv4 24.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local addr="$1"
    local ip="${addr%%/*}"
    local prefix="${addr##*/}"
    if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        utils::log_error "WireGuard interface address must be IPv4 CIDR (got: ${addr})"
        exit 1
    fi
    if [[ "${prefix}" != "24" ]]; then
        utils::log_error "Automatic peer allocation currently requires a /24 interface (got: ${addr})."
        utils::log_error "Either change WG_INTERFACE_ADDRESS to /24 or define WG_PEERS explicitly (legacy mode)."
        exit 1
    fi
}


wireguard::__ipv4_network_cidr() {
  # Purpose: Compute IPv4 network CIDR from an IPv4 interface CIDR.
  # Inputs: Positional parameter $1 = IPv4 CIDR, e.g. 10.66.66.1/24.
  # Outputs: Prints the normalized network CIDR, e.g. 10.66.66.0/24.
    local cidr="$1"
    local ip="${cidr%%/*}"
    local prefix="${cidr##*/}"
    local a b c d int mask net

    if [[ ! "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        utils::log_error "WireGuard interface address must be IPv4 CIDR (got: ${cidr})"
        exit 1
    fi
    if [[ ! "${prefix}" =~ ^[0-9]+$ ]] || (( prefix < 0 || prefix > 32 )); then
        utils::log_error "WireGuard interface prefix must be between 0 and 32 (got: ${cidr})"
        exit 1
    fi

    IFS=. read -r a b c d <<<"${ip}"
    for octet in "$a" "$b" "$c" "$d"; do
        if (( octet < 0 || octet > 255 )); then
            utils::log_error "WireGuard interface address contains an invalid octet (got: ${cidr})"
            exit 1
        fi
    done

    int=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    net=$(( int & mask ))

    printf '%d.%d.%d.%d/%d
'         $(( (net >> 24) & 255 ))         $(( (net >> 16) & 255 ))         $(( (net >> 8) & 255 ))         $(( net & 255 ))         "${prefix}"
}

wireguard::__registry_dir() {
  # Purpose: Registry dir.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    echo "${STATE_DIR}/wireguard"
}

wireguard::__registry_file() {
  # Purpose: Registry file.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    echo "$(wireguard::__registry_dir)/peers.json"
}

wireguard::__registry_init_if_missing() {
  # Purpose: Registry init if missing.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local reg_dir reg_file short iface
    reg_dir="$(wireguard::__registry_dir)"
    reg_file="$(wireguard::__registry_file)"
    short="$1"
    iface="$2"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        return 0
    fi

    utils::require_cmd jq "jq is required for WireGuard peer registry management. Install jq or run the full archarden flow." || exit 1

    fs::ensure_dir "${reg_dir}" 0700 root root

    if [[ -f "${reg_file}" ]]; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    jq -n --arg ss "${short}" --arg iface "${iface}" '{schema_version:1, server_shortname:$ss, interface_address:$iface, peers:[]}' >"${tmp}"
    utils::run_cmd "install -m 0600 -o root -g root \"${tmp}\" \"${reg_file}\""
    utils::run_cmd "rm -f \"${tmp}\""
}

wireguard::__registry_list_active() {
  # Purpose: Registry list active.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local reg_file
    reg_file="$(wireguard::__registry_file)"
    [[ -f "${reg_file}" ]] || return 0
    jq -r '.peers[]? | select(.revoked != true) | "\(.name)\t\(.address)\t\(.id)"' "${reg_file}"
}

wireguard::__registry_id_exists() {
  # Purpose: Registry id exists.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local id="$1" reg_file
    reg_file="$(wireguard::__registry_file)"
    [[ -f "${reg_file}" ]] || return 1
    jq -e --arg id "${id}" '.peers[]? | select(.id == $id) | .id' "${reg_file}" >/dev/null 2>&1
}

wireguard::__registry_append_peer() {
  # Purpose: Registry append peer.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local id="$1" name="$2" address="$3" created_at="$4"
    local reg_file tmp
    reg_file="$(wireguard::__registry_file)"
    tmp=$(mktemp)
    jq --arg id "${id}" --arg name "${name}" --arg addr "${address}" --arg created "${created_at}" \
      '.peers += [{id:$id, name:$name, address:$addr, created_at:$created, revoked:false}]' "${reg_file}" >"${tmp}"
    utils::run_cmd "install -m 0600 -o root -g root \"${tmp}\" \"${reg_file}\""
    utils::run_cmd "rm -f \"${tmp}\""
}

wireguard::__registry_import_legacy_peers() {
  # Purpose: Registry import legacy peers.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
  # Import WG_PEERS entries into the registry the first time the registry is created.
    local reg_file
    reg_file="$(wireguard::__registry_file)"
    [[ -f "${reg_file}" ]] || return 0

    local count
    count=$(jq -r '.peers | length' "${reg_file}" 2>/dev/null || echo 0)
    if [[ "${count}" != "0" ]]; then
        return 0
    fi

    if [[ ${#WG_PEERS[@]} -eq 0 ]]; then
        return 0
    fi

    local entry name addr id created
    for entry in "${WG_PEERS[@]}"; do
        IFS=":" read -r name addr <<<"${entry}"
        if [[ -z "${name}" || -z "${addr}" ]]; then
            utils::log_error "Invalid WireGuard peer entry '${entry}' in ${CONFIG_DIR}/wireguard.conf; expected name:address"
            exit 1
        fi
        # Generate an id for bookkeeping. Names are preserved.
        id=$(hexdump -n2 -e '"%04x"' /dev/urandom)
        while wireguard::__registry_id_exists "${id}"; do
            id=$(hexdump -n2 -e '"%04x"' /dev/urandom)
        done
        created=$(date -u +%FT%TZ)
        wireguard::__registry_append_peer "${id}" "${name}" "${addr}" "${created}"
    done
}

wireguard::_load_config() {
  # Purpose: Load config.
  # Inputs: Positional parameters $1..$3.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local cfg="${CONFIG_DIR}/wireguard.conf" entry name ip addr line
    if [[ ! -f "${cfg}" ]]; then
        utils::log_error "WireGuard config file not found at ${cfg}"
        exit 1
    fi

    # Preserve CLI-provided peer count across config sourcing.
    local cli_peer_count="${WG_PEERS_COUNT:-0}"

    # Legacy peers list (optional). Clear before sourcing so config can define it.
    WG_PEERS=()
    # shellcheck disable=SC1090
    source "${cfg}"

    # CLI wins.
    if [[ "${cli_peer_count}" != "0" ]]; then
        WG_PEERS_COUNT="${cli_peer_count}"
    fi

    if [[ -z "${WG_INTERFACE_ADDRESS:-}" || -z "${WG_LISTEN_PORT:-}" || -z "${WG_DNS:-}" ]]; then
        utils::log_error "WG_INTERFACE_ADDRESS, WG_LISTEN_PORT, and WG_DNS must be set in ${cfg}"
        exit 1
    fi

    WIREGUARD_SERVER_IP="${WG_INTERFACE_ADDRESS%%/*}"
    WIREGUARD_CLIENT_ALLOWED_IPS="$(wireguard::__ipv4_network_cidr "${WG_INTERFACE_ADDRESS}")"
    WIREGUARD_PEER_NAMES=()
    WIREGUARD_PEER_IPS=()

    local desired_count="${WG_PEERS_COUNT:-0}"
    if [[ "${desired_count}" == "0" ]]; then
        desired_count="1"
    fi

    local explicit_peers=0
    if [[ ${#WG_PEERS[@]} -gt 0 && "${cli_peer_count}" == "0" ]]; then
        explicit_peers=1
    fi

    local short
    short=$(wireguard::server_shortname)

    if [[ ${DRY_RUN} -eq 1 ]]; then
        if [[ ${explicit_peers} -eq 1 ]]; then
            for entry in "${WG_PEERS[@]}"; do
                IFS=":" read -r name ip <<<"${entry}"
                if [[ -z "${name}" || -z "${ip}" ]]; then
                    utils::log_error "Invalid WireGuard peer entry '${entry}' in ${cfg}; expected name:address"
                    exit 1
                fi
                WIREGUARD_PEER_NAMES+=("${name}")
                WIREGUARD_PEER_IPS+=("${ip}")
            done
        else
            wireguard::_require_ipv4_24 "${WG_INTERFACE_ADDRESS}"
            # Deterministic peer IDs in dry-run for stable tests.
            local base="${WIREGUARD_SERVER_IP%.*}" i id
            for i in $(seq 1 "${desired_count}"); do
                id=$(printf '%04x' "${i}")
                WIREGUARD_PEER_NAMES+=("${short}.${id}")
                WIREGUARD_PEER_IPS+=("${base}.$((i+1))/32")
            done
        fi
        WIREGUARD_CONFIG_LOADED=1
        return 0
    fi

    wireguard::__registry_init_if_missing "${short}" "${WG_INTERFACE_ADDRESS}"

    if [[ ${explicit_peers} -eq 1 ]]; then
        wireguard::__registry_import_legacy_peers
        # Populate runtime arrays from registry (no auto allocation).
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            name="${line%%$'	'*}"
            addr="${line#*$'	'}"; addr="${addr%%$'	'*}"
            WIREGUARD_PEER_NAMES+=("${name}")
            WIREGUARD_PEER_IPS+=("${addr}")
        done < <(wireguard::__registry_list_active)

        if [[ ${#WIREGUARD_PEER_NAMES[@]} -eq 0 ]]; then
            utils::log_error "No WireGuard peers available; define WG_PEERS in ${cfg} or use --wg-peers <N>"
            exit 1
        fi

        WIREGUARD_CONFIG_LOADED=1
        return 0
    fi

    # Automatic allocation uses a persisted registry.
    wireguard::_require_ipv4_24 "${WG_INTERFACE_ADDRESS}"

    local -a active_lines=()
    while IFS= read -r line; do
        [[ -n "${line}" ]] && active_lines+=("${line}")
    done < <(wireguard::__registry_list_active)

    # Track used host octets.
    local server_octet="${WIREGUARD_SERVER_IP##*.}"
    declare -A used
    used["${server_octet}"]=1

    local host_octet
    for line in "${active_lines[@]}"; do
        addr="${line#*$'	'}"; addr="${addr%%$'	'*}"
        host_octet="${addr%%/*}"; host_octet="${host_octet##*.}"
        used["${host_octet}"]=1
    done

    local active_count="${#active_lines[@]}"
    local needed=$(( desired_count - active_count ))
    if [[ ${needed} -lt 0 ]]; then
        needed=0
    fi

    local base="${WIREGUARD_SERVER_IP%.*}" created id name_new addr_new

    while [[ ${needed} -gt 0 ]]; do
        id=$(hexdump -n2 -e '"%04x"' /dev/urandom)
        while wireguard::__registry_id_exists "${id}"; do
            id=$(hexdump -n2 -e '"%04x"' /dev/urandom)
        done

        name_new="${short}.${id}"

        local h="" host
        for host in $(seq 2 254); do
            if [[ -z "${used[${host}]:-}" ]]; then
                h="${host}"
                break
            fi
        done
        if [[ -z "${h}" ]]; then
            utils::log_error "No available WireGuard client addresses left in ${WG_INTERFACE_ADDRESS}"
            exit 1
        fi
        used["${h}"]=1

        addr_new="${base}.${h}/32"
        created=$(date -u +%FT%TZ)
        wireguard::__registry_append_peer "${id}" "${name_new}" "${addr_new}" "${created}"

        active_lines+=("${name_new}"$'	'"${addr_new}"$'	'"${id}")
        needed=$((needed - 1))
    done

    # Populate runtime arrays from the final active list.
    for line in "${active_lines[@]}"; do
        name="${line%%$'	'*}"
        addr="${line#*$'	'}"; addr="${addr%%$'	'*}"
        WIREGUARD_PEER_NAMES+=("${name}")
        WIREGUARD_PEER_IPS+=("${addr}")
    done

    WIREGUARD_CONFIG_LOADED=1
}

wireguard::ensure_config_loaded() {
  # Purpose: Ensure config loaded.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    if [[ ${WIREGUARD_CONFIG_LOADED} -eq 0 ]]; then
        wireguard::_load_config
    fi
}

wireguard::__ensure_keypair() {
  # Purpose: Ensure keypair.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local name="$1" key_path="$2" pub_path="$3"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        utils::log_info "[DRY-RUN] Would ensure WireGuard keypair for ${name} at ${key_path}"
        return
    fi
    fs::ensure_dir /etc/wireguard/keys 0700
    if [[ ! -f "${key_path}" ]]; then
        utils::run_cmd "umask 077 && wg genkey > ${key_path}"
    fi
    if [[ ! -f "${pub_path}" ]]; then
        utils::run_cmd "umask 077 && wg pubkey < ${key_path} > ${pub_path}"
    fi
    utils::run_cmd "chmod 0600 ${key_path} ${pub_path}"
}

wireguard::__read_key() {
  # Purpose: Read key.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local path="$1" fallback="$2"
    if [[ -f "${path}" ]]; then
        tr -d '\n' < "${path}"
    else
        echo "${fallback}"
    fi
}

wireguard::__append_peer() {
  # Purpose: Append peer.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local tmp_file="$1" name="$2" pub_key="$3" allowed_ip="$4"
    if grep -q "PublicKey = ${pub_key}" "${tmp_file}"; then
        return
    fi
    {
        echo
        echo "[Peer]"
        echo "# ${name}"
        echo "PublicKey = ${pub_key}"
        echo "AllowedIPs = ${allowed_ip}"
        echo "PersistentKeepalive = 25"
    } >> "${tmp_file}"
}

wireguard::__ensure_server_config() {
  # Purpose: Ensure server config.
  # Inputs: Positional parameters $1..$1.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    wireguard::ensure_config_loaded
    local server_priv server_pub tmp wg_conf=/etc/wireguard/wg0.conf
    local -a peer_pub_keys=()
    if [[ ${DRY_RUN} -eq 1 ]]; then
        server_priv="DRY_RUN_SERVER_KEY"
        server_pub="DRY_RUN_SERVER_PUB"
        for name in "${WIREGUARD_PEER_NAMES[@]}"; do
            peer_pub_keys+=("DRY_RUN_${name^^}_PUB")
        done
    else
        wireguard::__ensure_keypair "server" /etc/wireguard/keys/server.key /etc/wireguard/keys/server.pub
        server_priv=$(wireguard::__read_key /etc/wireguard/keys/server.key "")
        server_pub=$(wireguard::__read_key /etc/wireguard/keys/server.pub "")
        local idx=0
        for name in "${WIREGUARD_PEER_NAMES[@]}"; do
            wireguard::__ensure_keypair "${name}" "/etc/wireguard/keys/${name}.key" "/etc/wireguard/keys/${name}.pub"
            peer_pub_keys[idx]=$(wireguard::__read_key "/etc/wireguard/keys/${name}.pub" "")
            ((idx += 1))
        done
        fs::ensure_dir "${STATE_DIR}/wireguard/clients" 0700 root root
    fi

    tmp=$(mktemp)
    if [[ ! -f "${wg_conf}" ]]; then
        cat <<EOT > "${tmp}"
[Interface]
Address = ${WG_INTERFACE_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = ${server_priv}
EOT
    else
        local in_interface=0 saw_address=0 saw_listen=0 saw_private=0
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if [[ "${line}" =~ ^\[.*\] ]]; then
                if [[ ${in_interface} -eq 1 ]]; then
                    if [[ ${saw_address} -eq 0 ]]; then
                        echo "Address = ${WG_INTERFACE_ADDRESS}" >> "${tmp}"
                    fi
                    if [[ ${saw_listen} -eq 0 ]]; then
                        echo "ListenPort = ${WG_LISTEN_PORT}" >> "${tmp}"
                    fi
                    if [[ ${saw_private} -eq 0 ]]; then
                        echo "PrivateKey = ${server_priv}" >> "${tmp}"
                    fi
                fi
                in_interface=0
            fi

            if [[ "${line}" == "[Interface]" ]]; then
                in_interface=1
                saw_address=0
                saw_listen=0
                saw_private=0
            elif [[ ${in_interface} -eq 1 ]]; then
                if [[ "${line}" =~ ^Address[[:space:]]*= ]]; then
                    line="Address = ${WG_INTERFACE_ADDRESS}"
                    saw_address=1
                elif [[ "${line}" =~ ^ListenPort[[:space:]]*= ]]; then
                    line="ListenPort = ${WG_LISTEN_PORT}"
                    saw_listen=1
                elif [[ "${line}" =~ ^PrivateKey[[:space:]]*= ]]; then
                    line="PrivateKey = ${server_priv}"
                    saw_private=1
                fi
            fi

            echo "${line}" >> "${tmp}"
        done < "${wg_conf}"

        if [[ ${in_interface} -eq 1 ]]; then
            if [[ ${saw_address} -eq 0 ]]; then
                echo "Address = ${WG_INTERFACE_ADDRESS}" >> "${tmp}"
            fi
            if [[ ${saw_listen} -eq 0 ]]; then
                echo "ListenPort = ${WG_LISTEN_PORT}" >> "${tmp}"
            fi
            if [[ ${saw_private} -eq 0 ]]; then
                echo "PrivateKey = ${server_priv}" >> "${tmp}"
            fi
        fi
    fi

    local i
    for i in "${!WIREGUARD_PEER_NAMES[@]}"; do
        wireguard::__append_peer "${tmp}" "${WIREGUARD_PEER_NAMES[i]}" "${peer_pub_keys[i]}" "${WIREGUARD_PEER_IPS[i]}"
    done

    utils::write_file_atomic "${wg_conf}" < "${tmp}"
    rm -f "${tmp}"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        utils::run_cmd "chmod 0600 ${wg_conf}"
        utils::run_cmd "chown root:root ${wg_conf}"
    fi
}

wireguard::__ensure_client_config() {
  # Purpose: Ensure client config.
  # Inputs: Positional parameters $1..$4.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    local name="${1-}" ip_addr="${2-}" server_pub="${3-}" endpoint="${4-}"
    if [[ -z "${name}" || -z "${ip_addr}" || -z "${server_pub}" || -z "${endpoint}" ]]; then
        utils::log_error "wireguard::__ensure_client_config requires name, ip_addr, server_pub, and endpoint"
        exit 1
    fi

    local key_path="/etc/wireguard/keys/${name}.key" pub_path="/etc/wireguard/keys/${name}.pub" client_conf="${STATE_DIR}/wireguard/clients/${name}.conf"
    local priv_key pub_key tmp
    if [[ ${DRY_RUN} -eq 1 ]]; then
        priv_key="DRY_RUN_${name^^}_KEY"
        pub_key="DRY_RUN_${name^^}_PUB"
    else
        wireguard::__ensure_keypair "${name}" "${key_path}" "${pub_path}"
        priv_key=$(wireguard::__read_key "${key_path}" "")
        pub_key=$(wireguard::__read_key "${pub_path}" "")
    fi

    tmp=$(mktemp)
    cat <<EOT > "${tmp}"
[Interface]
Address = ${ip_addr}
PrivateKey = ${priv_key}
DNS = ${WG_DNS}

[Peer]
PublicKey = ${server_pub}
Endpoint = ${endpoint}
AllowedIPs = ${WIREGUARD_CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOT

    utils::write_file_atomic "${client_conf}" < "${tmp}"
    rm -f "${tmp}"
    if [[ ${DRY_RUN} -eq 0 ]]; then
        utils::run_cmd "chmod 0600 ${client_conf}"
        utils::run_cmd "chown root:root ${client_conf}"
    fi
}

wireguard::configure() {
  # Purpose: Configure the requested state. (systemd)
  # Inputs: None.
  # Outputs: Return 0 on success; non-zero on error. Side effects depend on function.
    wireguard::ensure_config_loaded
    local server_pub endpoint_ip endpoint_host="YOUR_SERVER_IP" endpoint

    wireguard::__ensure_server_config
    server_pub=$(wireguard::__read_key /etc/wireguard/keys/server.pub "DRY_RUN_SERVER_PUB")
    endpoint_ip=$(steps::discover_public_ipv4)
    if [[ -n "${endpoint_ip}" ]]; then
        endpoint_host="${endpoint_ip}"
    else
        utils::log_warn "Could not detect public IPv4 address; using placeholder in WireGuard client configs"
    fi
    endpoint="${endpoint_host}:${WG_LISTEN_PORT}"

    local i
    for i in "${!WIREGUARD_PEER_NAMES[@]}"; do
        wireguard::__ensure_client_config "${WIREGUARD_PEER_NAMES[i]}" "${WIREGUARD_PEER_IPS[i]}" "${server_pub}" "${endpoint}"
    done

    if [[ ${DRY_RUN} -eq 0 ]]; then
        systemd::enable_now wg-quick@wg0.service
    else
        utils::log_info "[DRY-RUN] Would enable and start wg-quick@wg0.service"
    fi
    steps::run_status_capture "wg show wg0" wg show wg0
    steps::run_status_capture "systemctl is-active wg-quick@wg0" systemctl is-active wg-quick@wg0.service
    utils::log_info "WireGuard client configs available under ${STATE_DIR}/wireguard/clients"
}
