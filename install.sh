#!/usr/bin/env bash

set -u

SOURCE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALL_ROOT=${VPS_INSTALL_ROOT:-/usr/lib/vps-secure}
BIN_DIR=${VPS_BIN_DIR:-/usr/local/bin}
LINK_PATH="$BIN_DIR/vps"

require_root_for_system_paths() {
    case "$INSTALL_ROOT:$BIN_DIR" in
        /usr/*|/opt/*)
            if (( EUID != 0 )); then
                printf '安装到系统目录需要 root，请使用 sudo。\n' >&2
                return 30
            fi
            ;;
    esac
}

main() {
    local staging backup version timestamp
    require_root_for_system_paths || return $?
    version=$(<"$SOURCE_ROOT/VERSION")
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    staging="${INSTALL_ROOT}.new.$$"
    backup="${INSTALL_ROOT}.backup.${timestamp}"

    if [[ -e "$LINK_PATH" && ! -L "$LINK_PATH" ]]; then
        printf '拒绝覆盖已有普通文件: %s\n' "$LINK_PATH" >&2
        return 40
    fi

    [[ ! -e "$staging" ]] || {
        printf '临时安装目录已存在: %s\n' "$staging" >&2
        return 40
    }
    mkdir -p "$staging" "$BIN_DIR" || return 40
    cp -R "$SOURCE_ROOT/bin" "$SOURCE_ROOT/core" "$SOURCE_ROOT/modules" \
        "$SOURCE_ROOT/docs" "$staging/" || return 40
    cp "$SOURCE_ROOT/VERSION" "$SOURCE_ROOT/README.md" \
        "$SOURCE_ROOT/ARCHITECTURE.md" "$SOURCE_ROOT/MODULE_SPEC.md" \
        "$SOURCE_ROOT/COMPATIBILITY.md" "$staging/" || return 40
    chmod 755 "$staging/bin/vps"
    find "$staging/modules" -type f -name module.sh -exec chmod 755 {} +

    if [[ -e "$INSTALL_ROOT" ]]; then
        mv "$INSTALL_ROOT" "$backup" || return 40
    fi
    if ! mv "$staging" "$INSTALL_ROOT"; then
        [[ ! -e "$backup" ]] || mv "$backup" "$INSTALL_ROOT"
        return 40
    fi

    ln -sfn "$INSTALL_ROOT/bin/vps" "$LINK_PATH" || return 40

    printf 'VPS Secure Platform %s 已安装。\n' "$version"
    printf '命令入口: %s\n' "$LINK_PATH"
    [[ ! -e "$backup" ]] || printf '上一版本备份: %s\n' "$backup"
}

main "$@"
