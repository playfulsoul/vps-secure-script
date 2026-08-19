#!/usr/bin/env bash

set -u

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(<"$PROJECT_ROOT/VERSION")
DIST_DIR=${VPS_DIST_DIR:-$PROJECT_ROOT/dist}
ARCHIVE="$DIST_DIR/vps-secure-platform-$VERSION.tar.gz"

mkdir -p "$DIST_DIR"
tar -czf "$ARCHIVE" \
    --exclude=.git --exclude=dist --exclude=.DS_Store \
    -C "$PROJECT_ROOT" .

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
else
    shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
fi

printf '%s\n' "$ARCHIVE"
