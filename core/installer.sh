#!/usr/bin/env bash

vps_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        printf '缺少 SHA-256 校验工具。\n' >&2
        return 20
    fi
}

vps_archive_is_safe() {
    local archive=$1
    local entry type entries details

    entries=$(tar -tzf "$archive") || return 1
    while IFS= read -r entry; do
        case "$entry" in
            /*|../*|*/../*|*/..)
                printf '模块压缩包包含不安全路径: %s\n' "$entry" >&2
                return 1
                ;;
        esac
    done <<< "$entries"

    details=$(tar -tvzf "$archive") || return 1
    while IFS= read -r type; do
        case "$type" in
            l|h)
                printf '模块压缩包不允许包含符号链接或硬链接。\n' >&2
                return 1
                ;;
        esac
    done < <(printf '%s\n' "$details" | awk '{print substr($1, 1, 1)}')
}

vps_fetch_module_archive() {
    local source=$1
    local destination=$2

    case "$source" in
        https://*)
            command -v curl >/dev/null 2>&1 || return 20
            curl --fail --location --proto '=https' --tlsv1.2 \
                --output "$destination" "$source"
            ;;
        http://*)
            printf '拒绝通过未加密 HTTP 下载模块。\n' >&2
            return 20
            ;;
        *)
            [[ -f "$source" ]] || {
                printf '模块包不存在: %s\n' "$source" >&2
                return 20
            }
            cp "$source" "$destination"
            ;;
    esac
}

vps_install_module_archive() {
    local source=$1
    local expected_sha256=$2
    local install_root=${VPS_INSTALLED_MODULE_DIR:-/usr/local/lib/vps-secure/modules}
    local work_dir archive actual_sha256 manifests=() manifest module_dir
    local module_id version trust target candidate old_target transaction_dir existing_manifest
    local actual_normalized expected_normalized

    vps_require_root || return $?
    [[ "$expected_sha256" =~ ^[a-fA-F0-9]{64}$ ]] || {
        printf '必须提供有效的 SHA-256。\n' >&2
        return 64
    }

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vps-module.XXXXXX") || return 40
    archive="$work_dir/module.tar.gz"

    if ! vps_fetch_module_archive "$source" "$archive"; then
        rm -rf "$work_dir"
        return 40
    fi

    actual_sha256=$(vps_sha256 "$archive") || {
        rm -rf "$work_dir"
        return 40
    }
    actual_normalized=$(printf '%s' "$actual_sha256" | tr '[:upper:]' '[:lower:]')
    expected_normalized=$(printf '%s' "$expected_sha256" | tr '[:upper:]' '[:lower:]')
    if [[ "$actual_normalized" != "$expected_normalized" ]]; then
        printf '模块包 SHA-256 不匹配。\n' >&2
        rm -rf "$work_dir"
        return 40
    fi

    if ! vps_archive_is_safe "$archive"; then
        rm -rf "$work_dir"
        return 40
    fi

    mkdir "$work_dir/extracted" || { rm -rf "$work_dir"; return 40; }
    tar -xzf "$archive" -C "$work_dir/extracted" || { rm -rf "$work_dir"; return 40; }
    while IFS= read -r manifest; do
        manifests+=("$manifest")
    done < <(find "$work_dir/extracted" -maxdepth 2 -type f -name module.conf)
    if [[ ${#manifests[@]} -ne 1 ]]; then
        printf '模块包必须且只能包含一个 module.conf。\n' >&2
        rm -rf "$work_dir"
        return 64
    fi

    manifest=${manifests[0]}
    vps_validate_manifest "$manifest" || { rm -rf "$work_dir"; return 64; }
    module_dir=$(dirname -- "$manifest")
    module_id=$(vps_manifest_value "$manifest" id)
    version=$(vps_manifest_value "$manifest" version)
    trust=$(vps_manifest_value "$manifest" trust)
    if [[ "$trust" == builtin ]]; then
        printf '外部模块不能声明为 builtin。\n' >&2
        rm -rf "$work_dir"
        return 64
    fi

    existing_manifest=$(vps_module_find "$module_id" 2>/dev/null || true)
    if [[ -n "$existing_manifest" && "$existing_manifest" != "$install_root/$module_id/module.conf" ]]; then
        printf '模块 ID 与内置或其他来源冲突: %s\n' "$module_id" >&2
        rm -rf "$work_dir"
        return 64
    fi

    mkdir -p "$install_root" || { rm -rf "$work_dir"; return 40; }
    target="$install_root/$module_id"
    candidate="$install_root/.${module_id}.new.$$"
    old_target="$install_root/.${module_id}.old.$$"
    mkdir "$candidate" || { rm -rf "$work_dir"; return 40; }
    cp -R "$module_dir"/. "$candidate"/ || {
        rm -rf "$candidate" "$work_dir"
        return 40
    }

    chmod 755 "$candidate/$(vps_manifest_value "$manifest" entry)" || {
        rm -rf "$candidate" "$work_dir"
        return 40
    }

    transaction_dir=$(vps_new_transaction_dir module.installer) || {
        rm -rf "$candidate" "$work_dir"
        return 40
    }
    printf '%s\n' "$module_id" > "$transaction_dir/module_id"
    printf '%s\n' "$version" > "$transaction_dir/version"
    printf '%s\n' "$actual_sha256" > "$transaction_dir/sha256"
    if [[ -d "$target" ]]; then
        cp -R "$target" "$transaction_dir/previous" || {
            rm -rf "$candidate" "$work_dir"
            return 40
        }
        mv "$target" "$old_target" || { rm -rf "$candidate" "$work_dir"; return 40; }
    fi

    if ! mv "$candidate" "$target"; then
        [[ -d "$old_target" ]] && mv "$old_target" "$target"
        rm -rf "$candidate" "$work_dir"
        return 40
    fi
    rm -rf "$old_target" "$work_dir"
    vps_set_last_transaction module.installer "$transaction_dir" || return 40
    printf '模块 %s %s 已安装。\n' "$module_id" "$version"
}
