#!/usr/bin/env bash

vps_github_username_valid() {
    local username=${1:-}
    [[ "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]
}

vps_public_key_line_valid() {
    local line=${1:-}
    [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]]
}

vps_validate_public_key_file() {
    local key_file=$1 line count=0
    [[ -s "$key_file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        vps_public_key_line_valid "$line" || return 1
        count=$((count + 1))
        (( count <= 100 )) || return 1
    done < "$key_file"
    (( count > 0 ))
}

vps_merge_authorized_keys() {
    local existing_file=$1 imported_file=$2 output_file=$3
    awk 'NF && !seen[$0]++ { print }' "$existing_file" "$imported_file" > "$output_file"
}
