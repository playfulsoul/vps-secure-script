#!/usr/bin/env bash

set -u

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(<"$PROJECT_ROOT/VERSION")
DIST_DIR=${VPS_DIST_DIR:-$PROJECT_ROOT/dist}
ARCHIVE="$DIST_DIR/vps-secure-platform-$VERSION.tar.gz"
ARCHIVE_NAME=${ARCHIVE##*/}

mkdir -p "$DIST_DIR"
tar -czf "$ARCHIVE" \
    --exclude=.git --exclude=dist --exclude=.DS_Store \
    -C "$PROJECT_ROOT" .

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$DIST_DIR" && sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
else
    (cd "$DIST_DIR" && shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256")
fi

printf '%s\n' "$ARCHIVE"
