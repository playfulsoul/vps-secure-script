#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

actual=$("$PROJECT_ROOT/vps_secure.sh" --version)
assert_contains "$actual" 'legacy migration v1.0.3' "legacy raw entry is a migration assistant"
assert_contains "$actual" '2.0.0' "legacy migration points directly to the current stable package"
assert_contains "$(<"$PROJECT_ROOT/vps_secure.sh")" \
    '2640cb7446225815063491dbd0cd8edfeec0d301e2e7669b7f674e418b1c35c2' \
    "legacy migration pins the verified public archive SHA-256"

actual=$(printf '0\n' | "$PROJECT_ROOT/vps_secure.sh")
assert_contains "$actual" '1.x 单文件版本已经停止功能更新' "legacy users receive an end-of-maintenance notice"
assert_contains "$actual" '不会' "migration notice explains preserved server configuration"

temporary_root=$(mktemp -d)
fixture_root="$temporary_root/fixture"
fake_bin="$temporary_root/bin"
archive_name='vps-secure-platform-2.0.0.tar.gz'
mkdir -p "$fixture_root" "$fake_bin"
printf '%s\n' '2.0.0' > "$fixture_root/VERSION"
cat > "$fixture_root/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' installed > "$VPS_MIGRATION_TEST_MARKER"
EOF
chmod +x "$fixture_root/install.sh"
tar -czf "$temporary_root/$archive_name" -C "$fixture_root" .
checksum=$(shasum -a 256 "$temporary_root/$archive_name" | awk '{ print $1 }')
printf '%s  %s\n' "$checksum" "$archive_name" > "$temporary_root/$archive_name.sha256"

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
destination=''
url=''
while (( $# > 0 )); do
    case $1 in
        -o) destination=$2; shift 2 ;;
        http*) url=$1; shift ;;
        *) shift ;;
    esac
done
if [[ -n ${VPS_MIGRATION_DOWNLOAD_LOG:-} ]]; then
    printf '%s\n' "$url" >> "$VPS_MIGRATION_DOWNLOAD_LOG"
fi
case "$url" in
    *.sha256) cp "$VPS_MIGRATION_FIXTURE/$VPS_MIGRATION_ARCHIVE.sha256" "$destination" ;;
    *.tar.gz) cp "$VPS_MIGRATION_FIXTURE/$VPS_MIGRATION_ARCHIVE" "$destination" ;;
    *) exit 22 ;;
esac
EOF
chmod +x "$fake_bin/curl"

marker="$temporary_root/installed"
actual=$(PATH="$fake_bin:$PATH" \
    VPS_MIGRATION_ALLOW_NON_ROOT=yes \
    VPS_MIGRATION_SKIP_PLATFORM_CHECK=yes \
    VPS_MIGRATION_FIXTURE="$temporary_root" \
    VPS_MIGRATION_ARCHIVE="$archive_name" \
    VPS_MIGRATION_TARGET_SHA256="$checksum" \
    VPS_MIGRATION_TEST_MARKER="$marker" \
    VPS_MIGRATION_DOWNLOAD_LOG="$temporary_root/downloads.log" \
    VPS_MIGRATION_LINK_PATH="$temporary_root/vps" \
    VPS_MIGRATION_INSTALLED_ROOT="$temporary_root/not-installed" \
    "$PROJECT_ROOT/vps_secure.sh" --install --yes)
assert_file_exists "$marker" "verified migration package runs its installer"
assert_contains "$actual" '[完成]' "migration reports successful reinstallation"
assert_contains "$(<"$temporary_root/downloads.log")" \
    "https://github.com/playfulsoul/vps-secure-script/releases/download/v2.0.0/$archive_name" \
    "legacy migration selects the published stable archive URL"

printf '%064d  %s\n' 0 "$archive_name" > "$temporary_root/$archive_name.sha256"
bad_marker="$temporary_root/should-not-install"
actual=$(PATH="$fake_bin:$PATH" \
    VPS_MIGRATION_ALLOW_NON_ROOT=yes \
    VPS_MIGRATION_SKIP_PLATFORM_CHECK=yes \
    VPS_MIGRATION_FIXTURE="$temporary_root" \
    VPS_MIGRATION_ARCHIVE="$archive_name" \
    VPS_MIGRATION_TARGET_SHA256="$checksum" \
    VPS_MIGRATION_TEST_MARKER="$bad_marker" \
    VPS_MIGRATION_LINK_PATH="$temporary_root/vps" \
    VPS_MIGRATION_INSTALLED_ROOT="$temporary_root/not-installed" \
    "$PROJECT_ROOT/vps_secure.sh" --install --yes 2>&1 || true)
if [[ -e "$bad_marker" ]]; then
    fail "migration must reject a release checksum that differs from the pinned digest"
else
    pass "migration rejects a release checksum that differs from the pinned digest"
fi
assert_contains "$actual" '发布校验文件与内置 SHA-256 不一致' \
    "migration explains pinned release checksum rejection"

printf '%s  %s\n' "$checksum" "$archive_name" > "$temporary_root/$archive_name.sha256"
printf '%s\n' 'tampered' >> "$temporary_root/$archive_name"
tampered_marker="$temporary_root/tampered-should-not-install"
actual=$(PATH="$fake_bin:$PATH" \
    VPS_MIGRATION_ALLOW_NON_ROOT=yes \
    VPS_MIGRATION_SKIP_PLATFORM_CHECK=yes \
    VPS_MIGRATION_FIXTURE="$temporary_root" \
    VPS_MIGRATION_ARCHIVE="$archive_name" \
    VPS_MIGRATION_TARGET_SHA256="$checksum" \
    VPS_MIGRATION_TEST_MARKER="$tampered_marker" \
    VPS_MIGRATION_LINK_PATH="$temporary_root/vps" \
    VPS_MIGRATION_INSTALLED_ROOT="$temporary_root/not-installed" \
    "$PROJECT_ROOT/vps_secure.sh" --install --yes 2>&1 || true)
if [[ -e "$tampered_marker" ]]; then
    fail "migration must not run an archive that differs from the pinned digest"
else
    pass "migration rejects an archive that differs from the pinned digest"
fi
assert_contains "$actual" '安装包 SHA-256 校验失败' \
    "migration explains archive checksum rejection"

printf '%s\n' 'ID=centos' 'VERSION_ID="9"' > "$temporary_root/os-release"
actual=$(VPS_MIGRATION_ALLOW_NON_ROOT=yes \
    VPS_MIGRATION_OS_RELEASE_FILE="$temporary_root/os-release" \
    "$PROJECT_ROOT/vps_secure.sh" --install --yes 2>&1 || true)
assert_contains "$actual" '当前支持 Debian 11+ 和 Ubuntu 22.04+' \
    "migration stops before installing on an unsupported platform"

mkdir -p "$temporary_root/already-installed"
printf '%s\n' '2.0.0-beta.6.1' > "$temporary_root/already-installed/VERSION"
printf '%s\n' 'preserve existing entry' > "$temporary_root/existing-vps"
existing_result=0
actual=$(PATH="$fake_bin:$PATH" VPS_MIGRATION_ALLOW_NON_ROOT=yes \
    VPS_MIGRATION_SKIP_PLATFORM_CHECK=yes \
    VPS_MIGRATION_DOWNLOAD_LOG="$temporary_root/existing-downloads.log" \
    VPS_MIGRATION_LINK_PATH="$temporary_root/existing-vps" \
    VPS_MIGRATION_INSTALLED_ROOT="$temporary_root/already-installed" \
    "$PROJECT_ROOT/vps_secure.sh" --install --yes 2>&1) || existing_result=$?
assert_contains "$actual" '2.0.0-beta.6.1 已经安装' \
    "migration assistant does not replace an existing 2.x installation"
if [[ "$existing_result" == 10 && ! -e "$temporary_root/existing-downloads.log" &&
      $(<"$temporary_root/already-installed/VERSION") == 2.0.0-beta.6.1 &&
      $(<"$temporary_root/existing-vps") == 'preserve existing entry' ]]; then
    pass "existing 2.x installation stops migration before downloading or changing its entry"
else
    fail "existing 2.x installation must remain unchanged without downloading"
fi

rm -rf -- "$temporary_root"
finish_tests
