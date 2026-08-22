#!/usr/bin/env bash

set -u

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(<"$PROJECT_ROOT/VERSION")
DIST_DIR=${VPS_DIST_DIR:-$PROJECT_ROOT/dist}
ARCHIVE="$DIST_DIR/vps-secure-platform-$VERSION.tar.gz"
ARCHIVE_NAME=${ARCHIVE##*/}
TAR_OPTIONS=(-czf "$ARCHIVE")
ARCHIVE_MEMBERS=()

if [[ $(uname -s) == Darwin ]]; then
    # bsdtar otherwise stores macOS xattrs and file flags as pax headers. GNU
    # tar on Linux warns for every such header, obscuring the real installer
    # output and alarming users even though extraction succeeds.
    TAR_OPTIONS=(--no-xattrs --no-mac-metadata --no-fflags "${TAR_OPTIONS[@]}")
fi

mkdir -p "$DIST_DIR"

# Do not archive the project root as `.`. When a release built on macOS is
# extracted by root directly inside /root, tar may otherwise restore the
# archived `.` owner (for example uid 501, group staff) onto /root itself.
# Listing only the root's children keeps the flat release layout expected by
# the installer and updater without allowing extraction to mutate its parent.
while IFS= read -r -d '' member; do
    member=${member#"$PROJECT_ROOT"/}
    case $member in
        .git|dist|.DS_Store) continue ;;
    esac
    ARCHIVE_MEMBERS+=("$member")
done < <(find "$PROJECT_ROOT" -mindepth 1 -maxdepth 1 -print0)

(( ${#ARCHIVE_MEMBERS[@]} > 0 )) || {
    printf '没有可打包的发布文件。\n' >&2
    exit 1
}

tar "${TAR_OPTIONS[@]}" \
    --exclude=.git --exclude=dist --exclude=.DS_Store \
    -C "$PROJECT_ROOT" "${ARCHIVE_MEMBERS[@]}"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$DIST_DIR" && sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
else
    (cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
fi

printf '%s\n' "$ARCHIVE"
