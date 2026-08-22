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

vps_path_uid() {
    stat -c %u -- "$1" 2>/dev/null || stat -f %u "$1"
}

vps_path_gid() {
    stat -c %g -- "$1" 2>/dev/null || stat -f %g "$1"
}

vps_path_mode() {
    stat -c %a -- "$1" 2>/dev/null || stat -f %Lp "$1"
}

vps_ssh_secure_home() {
    local home=$1 expected_uid=$2 expected_gid=$3 current_uid current_gid
    [[ -d "$home" && ! -L "$home" ]] || {
        printf '拒绝使用不存在或符号链接形式的用户主目录: %s\n' "$home" >&2
        return 40
    }
    current_uid=$(vps_path_uid "$home") || return 40
    current_gid=$(vps_path_gid "$home") || return 40
    if [[ "$current_uid" != "$expected_uid" || "$current_gid" != "$expected_gid" ]]; then
        printf '[WARN] 用户主目录所有者异常，正在修复 %s（%s:%s -> %s:%s）。\n' \
            "$home" "$current_uid" "$current_gid" "$expected_uid" "$expected_gid"
        chown "$expected_uid:$expected_gid" "$home" || return 40
    fi
    chmod go-w "$home" || return 40
}

vps_ssh_paths_verify() {
    local home=$1 expected_uid=$2 expected_gid=$3
    local ssh_dir="$home/.ssh" authorized_keys="$home/.ssh/authorized_keys"
    local home_uid ssh_uid ssh_gid key_uid key_gid ssh_mode key_mode
    [[ -d "$home" && ! -L "$home" && -d "$ssh_dir" && ! -L "$ssh_dir" && \
       -f "$authorized_keys" && ! -L "$authorized_keys" ]] || {
        printf 'SSH 公钥路径不存在或包含不安全的符号链接。\n' >&2
        return 50
    }
    home_uid=$(vps_path_uid "$home") || return 50
    ssh_uid=$(vps_path_uid "$ssh_dir") || return 50
    ssh_gid=$(vps_path_gid "$ssh_dir") || return 50
    key_uid=$(vps_path_uid "$authorized_keys") || return 50
    key_gid=$(vps_path_gid "$authorized_keys") || return 50
    ssh_mode=$(vps_path_mode "$ssh_dir") || return 50
    key_mode=$(vps_path_mode "$authorized_keys") || return 50
    [[ "$home_uid" == "$expected_uid" ]] || {
        printf '用户主目录所有者异常，OpenSSH 可能拒绝公钥: %s\n' "$home" >&2
        return 50
    }
    [[ "$ssh_uid:$ssh_gid:$ssh_mode" == "$expected_uid:$expected_gid:700" ]] || {
        printf '.ssh 所有者或权限异常，应为 %s:%s 和 700。\n' "$expected_uid" "$expected_gid" >&2
        return 50
    }
    [[ "$key_uid:$key_gid:$key_mode" == "$expected_uid:$expected_gid:600" ]] || {
        printf 'authorized_keys 所有者或权限异常，应为 %s:%s 和 600。\n' \
            "$expected_uid" "$expected_gid" >&2
        return 50
    }
}
