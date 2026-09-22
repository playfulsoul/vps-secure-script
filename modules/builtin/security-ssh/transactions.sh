#!/usr/bin/env bash

# Reject symlinks in every component, including parents of the user's home.
ssh_tx_path() {
    local path=$1 part current=''
    [[ "$path" == /* && "$path" != *$'\n'* ]] || return 1
    local -a parts
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        [[ "$part" != . && "$part" != .. ]] || return 1
        current="$current/$part"
        [[ ! -L "$current" ]] || return 1
    done
}

ssh_tx_identity() {
    local stamp
    ssh_key_user_fields || return 1
    ssh_tx_path "$SSH_KEY_HOME/.ssh/authorized_keys" || return 1
    [[ -d "$SSH_KEY_HOME" ]] || return 1
    [[ ! -e "$SSH_KEY_HOME/.ssh" || -d "$SSH_KEY_HOME/.ssh" ]] || return 1
    [[ ! -e "$SSH_KEY_HOME/.ssh/authorized_keys" || -f "$SSH_KEY_HOME/.ssh/authorized_keys" ]] || return 1
    stamp=$(stat -c '%d:%i' "$SSH_KEY_HOME" 2>/dev/null || stat -f '%d:%i' "$SSH_KEY_HOME") || return 1
    printf '%s:%s:%s:%s:%s\n' "$SSH_KEY_TARGET_USER" "$SSH_KEY_UID" "$SSH_KEY_GID" "$SSH_KEY_HOME" "$stamp"
}

ssh_tx_phase() {
    printf '%s\n' "$2" > "$1/phase.next" && mv -f "$1/phase.next" "$1/phase"
}

ssh_tx_directory() {
    stat -c '%d:%i' "$SSH_KEY_HOME/.ssh" 2>/dev/null || stat -f '%d:%i' "$SSH_KEY_HOME/.ssh"
}

# Match key material, not comments. Conservatively skip keys already represented
# by a restricted authorization rather than add an unrestricted duplicate.
ssh_tx_key_present() {
    local line=$1 file=$2 type blob rest
    read -r type blob rest <<< "$line"
    awk -v type="$type" -v blob="$blob" '
        /^[[:space:]]*#/ { next }
        {
            # An options field can contain quoted whitespace. Only the first
            # three unquoted fields are relevant; never match a later comment.
            n=0; token=""; quoted=0; escaped=0
            for (i=1; i<=length($0)+1; i++) {
                c=(i<=length($0) ? substr($0,i,1) : " ")
                if (escaped) { token=token c; escaped=0; continue }
                if (c == "\\" && quoted) { token=token c; escaped=1; continue }
                if (c == "\"") { quoted=!quoted; token=token c; continue }
                if (c ~ /[[:space:]]/ && !quoted) {
                    if (length(token)) { field[++n]=token; token="" }
                    if (n == 3) break
                } else token=token c
            }
            if ((n>=2 && field[1]==type && field[2]==blob) ||
                (n>=3 && field[2]==type && field[3]==blob)) found=1
        }
        END { exit !found }
    ' "$file"
}

# Keep existing bytes, including blank lines and a missing final newline.
ssh_tx_append() {
    local original=$1 imported=$2 added=$3 output=$4 line last
    cp "$original" "$output" || return 1
    : > "$added" || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if ssh_tx_key_present "$line" "$original" || ssh_tx_key_present "$line" "$added"; then continue; fi
        printf '%s\n' "$line" >> "$added" || return 1
    done < "$imported"
    if [[ -s "$added" ]]; then
        if [[ -s "$output" ]]; then
            last=$(tail -c 1 "$output") || return 1
            [[ -z "$last" ]] || printf '\n' >> "$output" || return 1
        fi
        cat "$added" >> "$output" || return 1
    fi
}

# Only single, exact matches of recorded added lines are owned. Duplicated or
# edited lines are ambiguous and remain untouched. Preserve newline bytes.
ssh_tx_subtract() {
    local current=$1 added=$2 output=$3 line count ending
    : > "$output" || return 1
    # Both uses of current are read-only; output is a separate temporary file.
    # shellcheck disable=SC2094
    while :; do
        ending=yes
        IFS= read -r line || ending=no
        [[ "$ending" == yes || -n "$line" ]] || break
        if grep -Fxq -- "$line" "$added"; then
            count=$(grep -Fxc -- "$line" "$current") || return 1
            if [[ "$count" == 1 ]]; then continue; fi
            printf '保留无法唯一确认归属的重复公钥行。\n' >&2
        fi
        printf '%s' "$line" >> "$output" || return 1
        [[ "$ending" == no ]] || printf '\n' >> "$output" || return 1
    done < "$current"
}

# Atomic replacement, with a second identity/content check immediately before
# rename. The module lock serializes platform operations, not external editors.
ssh_tx_replace() {
    local source=$1 target=$2 snapshot=$3 expected=$4 present=$5 temporary now
    temporary=$(mktemp "$SSH_KEY_HOME/.ssh/.vps-key.XXXXXX") || return 1
    if ! install -m 600 -o "$SSH_KEY_UID" -g "$SSH_KEY_GID" "$source" "$temporary"; then
        rm -f -- "$temporary" || return 1
        return 1
    fi
    now=$(ssh_tx_identity) || { rm -f -- "$temporary"; return 1; }
    if [[ "$now" != "$expected" ]] ||
       [[ "$(ssh_tx_directory)" != "$SSH_TX_DIRECTORY" ]] ||
       { [[ "$present" == yes ]] && ! cmp -s "$target" "$snapshot"; } ||
       { [[ "$present" == no ]] && [[ -e "$target" ]]; }; then
        rm -f -- "$temporary" || return 1
        return 1
    fi
    if ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary" || return 1
        return 1
    fi
}

ssh_key_configure() (
    umask 077
    local state lock transaction='' expected target existed=no changed=no work='' previous phase path SSH_TX_DIRECTORY
    vps_require_root || return $?
    ssh_key_parse_args "$@" || return $?
    expected=$(ssh_tx_identity) || return 40
    ssh_key_user_fields || return 40
    target="$SSH_KEY_HOME/.ssh/authorized_keys"
    state=$(vps_module_state_dir "$MODULE_ID") || return 40
    ssh_tx_path "$state/transactions" || return 40
    mkdir -p "$state/transactions" || return 40
    chmod 700 "$state" "$state/transactions" || return 40
    lock="$state/operation-lock"
    mkdir "$lock" || { printf 'SSH 公钥操作锁存在，请先检查未完成事务。\n' >&2; return 40; }
    trap 'tx_rc=$?; [[ -z "$work" ]] || rm -rf -- "$work"; rmdir "$lock"; if (( tx_rc != 0 )); then printf "公钥导入未完成，请保留当前登录会话。事务：%s\n" "$transaction" >&2; fi' EXIT
    trap 'printf "SSH 公钥操作中断；请检查事务 %s。\n" "$transaction" >&2; exit 40' HUP INT TERM
    if [[ -e "$state/last_transaction" ]]; then
        ssh_tx_path "$state/last_transaction" || return 40
        previous=$(vps_last_transaction "$MODULE_ID") || return 40
        ssh_tx_path "$previous/phase" || return 40
        if [[ -f "$previous/phase" ]]; then
            IFS= read -r phase < "$previous/phase" || return 40
            case "$phase" in
                committed|rolled_back|compensated|failed) ;;
                *) printf '存在未完成公钥事务，拒绝覆盖恢复记录：%s\n' "$previous" >&2; return 40 ;;
            esac
        fi
    fi
    transaction=$(mktemp -d "$state/transactions/keys.XXXXXX") || return 40
    work=$(mktemp -d "$state/.work.XXXXXX") || return 40
    ssh_key_download "$work/imported" || return 30
    ssh_key_show_fingerprints "$work/imported" || return 30
    [[ "$(ssh_tx_identity)" == "$expected" ]] || return 40
    [[ ! -e "$target" ]] || existed=yes
    if [[ "$existed" == yes ]]; then cp -p "$target" "$transaction/original" || return 40
    else : > "$transaction/original" || return 40; fi
    printf '%s\n' "$SSH_KEY_TARGET_USER" > "$transaction/target_user" || return 40
    printf '%s\n' "$expected" > "$transaction/identity" || return 40
    printf '%s\n' "$existed" > "$transaction/existed" || return 40
    cp "$work/imported" "$transaction/imported.keys" || return 40
    printf '%s\n' "$target" > "$transaction/authorized_keys_path" || return 40
    ssh_tx_append "$transaction/original" "$work/imported" "$transaction/added" "$transaction/installed" || return 40
    # Preserve evidence of permission tightening; rollback never restores unsafe
    # modes or ownership. No SSH daemon settings are changed.
    for path in "$SSH_KEY_HOME" "$SSH_KEY_HOME/.ssh" "$target"; do
        if [[ -e "$path" ]]; then
            printf '%s %s %s %s\n' "$(vps_path_uid "$path")" "$(vps_path_gid "$path")" \
                "$(vps_path_mode "$path")" "$path" >> "$transaction/permissions.before" || return 40
        fi
    done
    ssh_tx_phase "$transaction" prepared || return 40
    # Publish recovery evidence before changing the user's file.
    vps_set_last_transaction "$MODULE_ID" "$transaction" || return 40
    [[ "$(ssh_tx_identity)" == "$expected" ]] || return 40
    ssh_key_secure_home || return 40
    install -d -m 700 -o "$SSH_KEY_UID" -g "$SSH_KEY_GID" "$SSH_KEY_HOME/.ssh" || return 40
    SSH_TX_DIRECTORY=$(ssh_tx_directory) || return 40
    printf '%s\n' "$SSH_TX_DIRECTORY" > "$transaction/ssh_directory" || return 40
    if ssh_tx_replace "$transaction/installed" "$target" "$transaction/original" "$expected" "$existed"; then changed=yes; fi
    if [[ "$changed" == yes ]] && ssh_key_paths_verify && ssh_tx_phase "$transaction" committed; then
        printf '公钥已导入。请保持当前窗口，并新开窗口验证密钥登录；验证成功前不要关闭密码登录。\n'
        return 0
    fi
    if [[ "$changed" == yes ]]; then
        if [[ "$(ssh_tx_identity)" == "$expected" ]] && cmp -s "$target" "$transaction/installed" &&
           ssh_tx_replace "$transaction/original" "$target" "$transaction/installed" "$expected" yes; then
            if [[ "$existed" == no ]]; then rm -f -- "$target" || return 60; fi
            ssh_tx_phase "$transaction" compensated || return 60
            printf '导入失败，已恢复原授权内容；保留事务证据。\n' >&2
        else
            printf '导入失败且自动恢复失败，请检查事务：%s\n' "$transaction" >&2
            return 60
        fi
    else
        ssh_tx_phase "$transaction" failed || return 60
    fi
    return 40
)

ssh_key_rollback() (
    umask 077
    local state lock transaction expected actual target phase existed work='' SSH_TX_DIRECTORY
    vps_require_root || return $?
    state=$(vps_module_state_dir "$MODULE_ID") || return 60
    ssh_tx_path "$state" || return 60
    lock="$state/operation-lock"
    mkdir "$lock" || return 60
    trap 'tx_rc=$?; [[ -z "$work" ]] || rm -rf -- "$work"; rmdir "$lock"; if (( tx_rc != 0 )); then printf "公钥回滚未完成，保留当前授权和事务证据，请人工核对。\n" >&2; fi' EXIT
    ssh_tx_path "$state/last_transaction" || return 60
    transaction=$(vps_last_transaction "$MODULE_ID") || return 60
    ssh_tx_path "$transaction" || return 60
    # Old transactions lack proof of exactly what was added; never restore the
    # entire historical file over a user's newer authorizations.
    local name
    for name in identity target_user existed added original installed phase ssh_directory; do
        [[ -f "$transaction/$name" && ! -L "$transaction/$name" ]] || {
            printf '事务缺少安全回滚证据，保留当前密钥；请人工核对备份。\n' >&2; return 60;
        }
    done
    IFS= read -r SSH_KEY_TARGET_USER < "$transaction/target_user" || return 60
    IFS= read -r expected < "$transaction/identity" || return 60
    actual=$(ssh_tx_identity) || return 60
    [[ "$actual" == "$expected" ]] || return 60
    ssh_key_user_fields || return 60
    IFS= read -r SSH_TX_DIRECTORY < "$transaction/ssh_directory" || return 60
    [[ "$(ssh_tx_directory)" == "$SSH_TX_DIRECTORY" ]] || return 60
    target="$SSH_KEY_HOME/.ssh/authorized_keys"
    IFS= read -r phase < "$transaction/phase" || return 60
    [[ "$phase" != rolled_back ]] || { printf '本次公钥导入已撤销。\n'; return 0; }
    [[ "$phase" == committed ]] || {
        printf '事务未完成，请人工核对后恢复：%s\n' "$transaction" >&2; return 60;
    }
    IFS= read -r existed < "$transaction/existed" || return 60
    [[ -f "$target" ]] || { ssh_tx_phase "$transaction" rolled_back; return $?; }
    work=$(mktemp -d "$state/.work.XXXXXX") || return 60
    cp -p "$target" "$work/current" || return 60
    if cmp -s "$target" "$transaction/installed"; then
        cp "$transaction/original" "$work/result" || return 60
    else
        ssh_tx_subtract "$work/current" "$transaction/added" "$work/result" || return 60
    fi
    ssh_tx_phase "$transaction" rollback_pending || return 60
    ssh_tx_replace "$work/result" "$target" "$work/current" "$expected" yes || return 60
    if [[ "$existed" == no && ! -s "$work/result" ]]; then
        [[ "$(ssh_tx_identity)" == "$expected" ]] && cmp -s "$target" "$work/result" || return 60
        rm -f -- "$target" || return 60
    fi
    ssh_tx_phase "$transaction" rolled_back || return 60
    printf '已撤销可确认的本次新增公钥，保留其他授权内容。\n'
)
