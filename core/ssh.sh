#!/usr/bin/env bash

# Read-only OpenSSH capability helpers. This file may be sourced by the CLI and
# by modules; it must not change sshd configuration or firewall state.

vps_is_valid_port() {
    local port=${1:-}
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

vps_ssh_connection_port() {
    local connection=${1:-${SSH_CONNECTION:-}}
    local client_address client_port server_address server_port extra

    read -r client_address client_port server_address server_port extra <<< "$connection"
    if [[ -n "${extra:-}" ]] || ! vps_is_valid_port "${server_port:-}"; then
        return 1
    fi

    printf '%s\n' "$server_port"
}

vps_find_sshd() {
    if [[ -n "${VPS_SSHD_BIN:-}" && -x "$VPS_SSHD_BIN" ]]; then
        printf '%s\n' "$VPS_SSHD_BIN"
    elif command -v sshd >/dev/null 2>&1; then
        command -v sshd
    elif [[ -x /usr/sbin/sshd ]]; then
        printf '%s\n' /usr/sbin/sshd
    else
        return 1
    fi
}

vps_sshd_effective_ports() {
    local sshd_bin
    sshd_bin=$(vps_find_sshd) || return 1

    "$sshd_bin" -T 2>/dev/null |
        awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2 }'
}

vps_active_sshd_ports() {
    command -v ss >/dev/null 2>&1 || return 1

    ss -H -lntp 2>/dev/null |
        awk '$0 ~ /\(\("sshd"/ { print $4 }' |
        while IFS= read -r address; do
            local port=${address##*:}
            if vps_is_valid_port "$port"; then
                printf '%s\n' "$port"
            fi
        done
}

vps_detect_ssh_ports() {
    local detected=''
    local current_port=''

    current_port=$(vps_ssh_connection_port 2>/dev/null || true)
    if [[ -n "$current_port" ]]; then
        detected+="$current_port"$'\n'
    fi

    detected+="$(vps_active_sshd_ports 2>/dev/null || true)"$'\n'
    detected+="$(vps_sshd_effective_ports 2>/dev/null || true)"$'\n'

    printf '%s' "$detected" |
        awk '/^[0-9]+$/ && $1 >= 1 && $1 <= 65535 { seen[$1] = 1 } END { for (port in seen) print port }' |
        sort -n
}

vps_require_ssh_ports() {
    local ports
    ports=$(vps_detect_ssh_ports)

    if [[ -z "$ports" ]]; then
        return 1
    fi

    printf '%s\n' "$ports"
}
