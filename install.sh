#!/usr/bin/env bash

set -u

SOURCE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=core/build_identity.sh
source "$SOURCE_ROOT/core/build_identity.sh"
# shellcheck source=core/install_transaction.sh
source "$SOURCE_ROOT/core/install_transaction.sh"
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

prepare_install() (
    local source=$1 staging=$2 build_id
    umask 022
    build_id=$(vps_verify_build_identity "$source") || return $?
    mkdir -- "$staging" || return 40
    cp -R "$SOURCE_ROOT/bin" "$SOURCE_ROOT/core" "$SOURCE_ROOT/modules" \
        "$SOURCE_ROOT/docs" "$staging/" || return 40
    cp "$SOURCE_ROOT/VERSION" "$SOURCE_ROOT/README.md" \
        "$SOURCE_ROOT/ARCHITECTURE.md" "$SOURCE_ROOT/MODULE_SPEC.md" \
        "$SOURCE_ROOT/COMPATIBILITY.md" "$staging/" || return 40
    printf '%s\n' "$build_id" > "$staging/BUILD_ID" || return 40
    if [[ -r "$SOURCE_ROOT/BUILD_MANIFEST.sha256" ]]; then
        cp "$SOURCE_ROOT/BUILD_MANIFEST.sha256" "$staging/" || return 40
    else
        vps_build_manifest "$SOURCE_ROOT" "$staging/BUILD_MANIFEST.sha256" || return 40
    fi
    chmod 755 "$staging/bin/vps" || return 40
    find "$staging/modules" -type f -name module.sh -exec chmod 755 {} + || return 40
)

main() {
    require_root_for_system_paths || return $?
    vps_install_transaction "$INSTALL_ROOT" "$LINK_PATH" prepare_install "$SOURCE_ROOT"
}

main "$@"
