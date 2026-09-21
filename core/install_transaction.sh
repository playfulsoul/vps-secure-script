#!/usr/bin/env bash

# Shared only by the platform installer and platform version restoration.
# Call vps_install_transaction in a subshell so traps never replace CLI traps.
vps_tx_exists() { [[ -e "$1" || -L "$1" ]]; }

vps_tx_trusted_parent() {
    local path=$1 mode owner
    while :; do
        owner=$(stat -c %u "$path" 2>/dev/null || stat -f %u "$path") || return 40
        mode=$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path") || return 40
        [[ "$owner" == 0 || "$owner" == "$EUID" ]] || return 40
        if (( (8#$mode & 0022) != 0 )); then
            # Root-owned sticky temporary parents are safe against other users
            # renaming our owned children; other writable ancestors are refused.
            [[ "$owner" == 0 ]] && (( (8#$mode & 01000) != 0 )) || return 40
        fi
        [[ "$path" != / ]] || break
        path=$(dirname -- "$path")
    done
}

vps_tx_path() {
    local path=$1 parent physical
    [[ "$path" == /* && "$path" != / && "$path" != */ &&
       "$path" != *$'\n'* && "$path" != *'/../'* && "$path" != */.. &&
       "$path" != *'/./'* && "$path" != */. ]] || return 40
    parent=$(dirname -- "$path")
    physical=$(cd -- "$parent" && pwd -P) || return 40
    [[ "$parent" == "$physical" && ! -L "$path" ]] || return 40
    vps_tx_trusted_parent "$parent"
}

vps_tx_check_install() {
    local root=$1 expected_version=${2:-} expected_build=${3:-} version build='' output unsafe
    [[ -d "$root" && ! -L "$root" && -f "$root/VERSION" &&
       -x "$root/bin/vps" && -d "$root/core" && -d "$root/modules" ]] || return 40
    unsafe=$(find "$root" \( -type l -o -perm -0020 -o -perm -0002 -o \( ! -user "$EUID" ! -user 0 \) \) -print) || return 40
    [[ -z "$unsafe" ]] || { printf '安装或备份包含不可信文件，已拒绝执行。\n' >&2; return 40; }
    version=$(<"$root/VERSION")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 40
    [[ -z "$expected_version" || "$version" == "$expected_version" ]] || return 40
    if [[ -e "$root/BUILD_ID" ]]; then
        build=$(<"$root/BUILD_ID")
        [[ "$build" =~ ^sha256-[a-f0-9]{64}$ ]] || return 40
    fi
    [[ -z "$expected_build" || "$build" == "$expected_build" ]] || return 40
    # Installed trees intentionally omit release-only files. Check the runnable
    # installed subset, not the full release manifest. Legacy backups lack ID.
    output=$("$root/bin/vps" --version 2>&1) || return 40
    [[ "$output" == "vps-secure $version" || "$output" == "vps-secure $version (build "*')' ]] || return 40
    [[ -z "$build" || "$output" == "vps-secure $version (build $build)" ]] || return 40
}

vps_tx_phase() { printf '%s\n' "$1" > "$tx_dir/phase"; }

vps_tx_finish() {
    local result=$1 failed=0
    trap - EXIT HUP INT TERM
    if [[ "$tx_committed" != yes && "$tx_switching" == yes ]]; then
        # Infer rename completion from disk, including a signal delivered just
        # after mv succeeded. Never overwrite any backup or failed candidate.
        if vps_tx_exists "$tx_backup"; then
            if vps_tx_exists "$tx_root"; then
                mv -- "$tx_root" "$tx_dir/failed-install" || failed=1
            fi
            if ! vps_tx_exists "$tx_root"; then
                mv -- "$tx_backup" "$tx_root" || failed=1
            else
                failed=1
            fi
        elif [[ "$tx_had_old" == no ]] && vps_tx_exists "$tx_root"; then
            mv -- "$tx_root" "$tx_dir/failed-install" || failed=1
        fi
        if [[ "$tx_link_changed" == yes ]]; then
            if [[ "$tx_old_link" == absent ]]; then
                if [[ -L "$tx_link" ]]; then rm -- "$tx_link" || failed=1; fi
            else
                ln -sfn -- "$tx_old_link" "$tx_link" || failed=1
            fi
        fi
        if [[ "$tx_had_old" == yes ]]; then
            vps_tx_check_install "$tx_root" || failed=1
            [[ "$tx_old_link" == absent || $(readlink "$tx_link") == "$tx_old_link" ]] || failed=1
        fi
        if (( failed )); then
            vps_tx_phase recovery-failed
            printf '恢复也未完成；已保留备份与事务：%s。请勿删除锁或备份。\n' "$tx_dir" >&2
            printf '安装路径：%s；原版本备份：%s；入口：%s\n' "$tx_root" "$tx_backup" "$tx_link" >&2
            exit 60
        fi
        printf '操作未完成，原有安装与入口已保留/恢复。事务：%s\n' "$tx_dir" >&2
    fi
    if [[ "$tx_committed" != yes ]]; then vps_tx_phase aborted || result=60; fi
    # The lock is exclusively owned by this process; transaction evidence stays.
    if ! rm -- "$tx_lock/transaction" || ! rmdir -- "$tx_lock"; then
        printf '事务锁未能释放，请检查 %s；不要重复安装。\n' "$tx_lock" >&2
        exit 60
    fi
    exit "$result"
}

vps_install_transaction() (
    # Subshell-private variables must remain visible to EXIT even when Bash 3
    # unwinds a function after an error or signal.
    tx_root=$1 tx_link=$2 prepare=$3 source=$4
    tx_old_link=absent tx_had_old=no tx_link_changed=no
    tx_committed=no tx_switching=no build=''
    umask 077
    # Parents may be created for an isolated or first-time installation, but
    # aliases and symlink targets are rejected before any version is moved.
    [[ "$tx_root" == /* && "$tx_link" == /* && "$tx_root" != / &&
       "$tx_root" != */ && "$tx_root" != *'/../'* && "$tx_root" != */.. &&
       "$tx_root" != *'/./'* && "$tx_root" != */. && "$tx_root" != *$'\n'* &&
       "$tx_link" != *$'\n'* && "$tx_link" == */vps ]] || return 40
    mkdir -p -- "$(dirname -- "$tx_root")" "$(dirname -- "$tx_link")" || return 40
    tx_root="$(cd -- "$(dirname -- "$tx_root")" && pwd -P)/$(basename -- "$tx_root")"
    tx_link="$(cd -- "$(dirname -- "$tx_link")" && pwd -P)/vps"
    vps_tx_path "$tx_root" || { printf '安装目录路径不安全。\n' >&2; return 40; }
    parent=$(dirname -- "$tx_link")
    [[ "$(cd -- "$parent" && pwd -P)" == "$parent" && "$tx_link" != "$tx_root"/* ]] || return 40
    vps_tx_trusted_parent "$parent" || return 40
    if vps_tx_exists "$tx_link" && [[ ! -L "$tx_link" ]]; then
        printf '拒绝覆盖已有普通文件: %s\n' "$tx_link" >&2; return 40
    fi
    tx_lock="$tx_root.operation-lock"
    if ! mkdir -- "$tx_lock" 2>/dev/null; then
        printf '另一个安装/恢复正在进行，或上次操作中断。请检查 %s；不要自动删除锁，先确认进程和事务记录。\n' "$tx_lock" >&2
        return 30
    fi
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    tx_dir=$(mktemp -d "$tx_root.transaction.$timestamp.XXXXXX") || { rmdir -- "$tx_lock"; return 40; }
    # A fixed-width sequence orders backups made during the same second. The
    # operation lock serializes this allocation; the final target is rechecked.
    sequence=0
    for existing in "$tx_root.backup.$timestamp."*; do
        number=${existing##*.}
        if [[ "$number" =~ ^[0-9]{9}$ ]]; then
            (( 10#$number <= sequence )) || sequence=$((10#$number))
        fi
    done
    (( sequence < 999999999 )) || return 40
    printf -v suffix '%09d' "$((sequence + 1))"
    tx_backup="$tx_root.backup.$timestamp.$suffix"
    tx_candidate="$tx_dir/candidate"
    printf '%s\n' "$tx_dir" > "$tx_lock/transaction" || return 40
    printf 'pid=%s\nroot=%s\nlink=%s\nbackup=%s\n' "$$" "$tx_root" "$tx_link" "$tx_backup" > "$tx_dir/paths" || return 40
    if [[ -L "$tx_link" ]]; then tx_old_link=$(readlink "$tx_link") || return 40; fi
    printf '%s\n' "$tx_old_link" > "$tx_dir/old-link" || return 40
    trap 'vps_tx_finish $?' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
    if vps_tx_exists "$tx_root"; then
        tx_had_old=yes
        vps_tx_check_install "$tx_root" || { printf '现有安装不完整；请先检查，未切换版本。\n' >&2; return 40; }
    fi
    vps_tx_phase preparing || return 40
    "$prepare" "$source" "$tx_candidate" || return 40
    vps_tx_check_install "$tx_candidate" || return 40
    version=$(<"$tx_candidate/VERSION")
    [[ ! -e "$tx_candidate/BUILD_ID" ]] || build=$(<"$tx_candidate/BUILD_ID")
    vps_tx_exists "$tx_backup" && { printf '拒绝覆盖已有备份：%s\n' "$tx_backup" >&2; return 40; }
    vps_tx_phase switching || return 40
    tx_switching=yes
    if [[ "$tx_had_old" == yes ]]; then
        mv -- "$tx_root" "$tx_backup" || return 40
    fi
    mv -- "$tx_candidate" "$tx_root" || return 40
    # Set before ln so partial link changes are compensated too.
    tx_link_changed=yes
    ln -sfn -- "$tx_root/bin/vps" "$tx_link" || return 40
    vps_tx_check_install "$tx_root" "$version" "$build" || return 40
    [[ -L "$tx_link" && $(readlink "$tx_link") == "$tx_root/bin/vps" ]] || return 40
    "$tx_link" --version >/dev/null || return 40
    vps_tx_phase committed || return 40
    tx_committed=yes
    printf '平台版本 %s 已安装并验证。\n事务记录：%s\n' "$version" "$tx_dir"
    [[ "$tx_had_old" == no ]] || printf '上一版本备份: %s\n' "$tx_backup"
)

vps_tx_copy_backup() {
    vps_tx_path "$1" && vps_tx_check_install "$1" || return 40
    cp -Rp -- "$1" "$2"
}
