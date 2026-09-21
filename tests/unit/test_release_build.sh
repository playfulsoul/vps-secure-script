#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

temporary_dist=$(mktemp -d)
blocked_dist="$temporary_dist/not-a-directory"
printf '%s\n' 'occupied' > "$blocked_dist"
if VPS_DIST_DIR="$blocked_dist" "$PROJECT_ROOT/scripts/build-release.sh" >/dev/null 2>&1; then
    fail "release builder must fail when the output directory cannot be created"
else
    pass "release builder fails closed when the output directory is unavailable"
fi

version=$(<"$PROJECT_ROOT/VERSION")
archive=$(VPS_DIST_DIR="$temporary_dist" "$PROJECT_ROOT/scripts/build-release.sh")
archive_name=${archive##*/}
legacy_archive_name="vps-secure-platform-$version.tar.gz"

assert_file_exists "$temporary_dist/$archive_name" "release builder creates the versioned archive"
assert_file_exists "$temporary_dist/$archive_name.sha256" "release builder creates the checksum file"
assert_file_exists "$temporary_dist/$legacy_archive_name" \
    "release builder keeps a legacy-named asset for installed older clients"
assert_file_exists "$temporary_dist/$legacy_archive_name.sha256" \
    "release builder creates the legacy asset checksum"

if (cd "$temporary_dist" && sha256sum -c "$archive_name.sha256" >/dev/null); then
    pass "release archive matches its SHA-256 file"
else
    fail "release archive must match its SHA-256 file"
fi

if (cd "$temporary_dist" && sha256sum -c "$legacy_archive_name.sha256" >/dev/null); then
    pass "legacy-named release asset matches its SHA-256 file"
else
    fail "legacy-named release asset must match its SHA-256 file"
fi

if cmp -s "$temporary_dist/$archive_name" "$temporary_dist/$legacy_archive_name"; then
    pass "identity and legacy asset names contain identical bytes"
else
    fail "legacy compatibility asset must be identical to the identity asset"
fi

actual=$(tar -xOf "$temporary_dist/$archive_name" VERSION)
assert_eq "$version" "$actual" "release archive contains the expected platform version"

build_id=$(tar -xOf "$temporary_dist/$archive_name" BUILD_ID)
if [[ "$build_id" =~ ^sha256-[a-f0-9]{64}$ ]]; then
    pass "release archive contains a complete content build identity"
else
    fail "release archive must contain a complete content build identity"
fi
assert_contains "$archive_name" "vps-secure-platform-$version-build.$build_id.tar.gz" \
    "archive name carries the same build identity as its content"

tar -xOf "$temporary_dist/$archive_name" BUILD_MANIFEST.sha256 \
    > "$temporary_dist/BUILD_MANIFEST.sha256"
manifest_digest=$(shasum -a 256 "$temporary_dist/BUILD_MANIFEST.sha256" | awk '{print $1}')
assert_eq "$build_id" "sha256-$manifest_digest" \
    "build identity matches the archived source manifest"

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

install_root="$temporary_dist/install-root"
VPS_INSTALL_ROOT="$install_root/lib/vps-secure" \
VPS_BIN_DIR="$install_root/bin" \
    "$extract_dir/install.sh" >/dev/null
installed_version=$("$install_root/bin/vps" --version)
assert_contains "$installed_version" "$build_id" \
    "archive, checksum, and installed command retain one traceable identity"

printf '\n# identity regression fixture\n' >> "$extract_dir/modules/builtin/system-doctor/module.sh"
if VPS_INSTALL_ROOT="$temporary_dist/tampered/lib/vps-secure" \
    VPS_BIN_DIR="$temporary_dist/tampered/bin" \
    "$extract_dir/install.sh" >/dev/null 2>&1; then
    fail "installer must reject content changed after build identity generation"
else
    pass "installer rejects content changed after build identity generation"
fi

variant_root="$temporary_dist/variant-source"
cp -R "$PROJECT_ROOT" "$variant_root"
printf '\nBuild identity test variant.\n' >> "$variant_root/README.md"
variant_dist="$temporary_dist/variant-dist"
variant_archive=$(VPS_DIST_DIR="$variant_dist" "$variant_root/scripts/build-release.sh")
variant_build=$(tar -xOf "$variant_archive" BUILD_ID)
if [[ "$variant_build" == "$build_id" ]]; then
    fail "content-different candidates must not share a visible build identity"
else
    pass "content-different candidates receive different visible build identities"
fi

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
