#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

temporary_dist=$(mktemp -d)
version=$(<"$PROJECT_ROOT/VERSION")
archive_name="vps-secure-platform-$version.tar.gz"

VPS_DIST_DIR="$temporary_dist" "$PROJECT_ROOT/scripts/build-release.sh" >/dev/null

assert_file_exists "$temporary_dist/$archive_name" "release builder creates the versioned archive"
assert_file_exists "$temporary_dist/$archive_name.sha256" "release builder creates the checksum file"

if (cd "$temporary_dist" && sha256sum -c "$archive_name.sha256" >/dev/null); then
    pass "release archive matches its SHA-256 file"
else
    fail "release archive must match its SHA-256 file"
fi

actual=$(tar -xOf "$temporary_dist/$archive_name" VERSION)
assert_eq "$version" "$actual" "release archive contains the expected platform version"

if tar -tzf "$temporary_dist/$archive_name" | grep -Eq '^\./?$'; then
    fail "release archive must not contain a parent-directory entry"
else
    pass "release archive cannot change the extraction directory metadata"
fi

extract_dir="$temporary_dist/extracted"
mkdir "$extract_dir"
chmod 711 "$extract_dir"
before_mode=$(stat -c %a "$extract_dir" 2>/dev/null || stat -f %Lp "$extract_dir")
tar -xzf "$temporary_dist/$archive_name" -C "$extract_dir"
after_mode=$(stat -c %a "$extract_dir" 2>/dev/null || stat -f %Lp "$extract_dir")
assert_eq "$before_mode" "$after_mode" "release extraction preserves its parent directory mode"
assert_file_exists "$extract_dir/install.sh" "flat release layout remains installable"

if [[ $(uname -s) == Darwin ]] && command -v strings >/dev/null 2>&1; then
    if gzip -dc "$temporary_dist/$archive_name" | strings |
        grep -Eq 'LIBARCHIVE\.xattr|SCHILY\.fflags|apple\.fileprovider'; then
        fail "macOS release archive must not contain Apple metadata headers"
    else
        pass "macOS release archive omits Apple metadata headers"
    fi
fi

rm -rf -- "$temporary_dist"
finish_tests
