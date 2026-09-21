#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
CLI="$PROJECT_ROOT/bin/vps"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

actual=$("$CLI" module run applications.1panel plan)
assert_contains "$actual" '使用平台目录中的 SHA-256' \
    "1Panel plan uses a platform-maintained installer checksum"
assert_contains "$actual" '官方安装器仍会继续下载' \
    "1Panel plan explains the downstream download boundary"

remote_root=$(mktemp -d)
mkdir -p "$remote_root/bin"
printf '%s\n' 'ID=debian' 'VERSION_ID="12"' > "$remote_root/os-release"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$remote_root/bin/apt-get"
chmod +x "$remote_root/bin/apt-get"
actual=$(PATH="$remote_root/bin:$PATH" \
    VPS_OS_RELEASE_FILE="$remote_root/os-release" \
    VPS_REMOTE_DESKTOP_MEMORY_MB=2048 \
    VPS_REMOTE_DESKTOP_CPU_COUNT=2 \
    VPS_REMOTE_DESKTOP_FREE_DISK_MB=20000 \
    "$CLI" module run applications.remote-desktop plan \
        --profile xfce --user desktop --create-user --browser none --set-password)
assert_contains "$actual" 'XFCE 推荐版' "remote desktop plan identifies the selected profile"
assert_contains "$actual" 'fonts-noto-cjk' \
    "remote desktop plan includes Chinese display fonts"
assert_contains "$actual" '仅监听 127.0.0.1:3389' \
    "remote desktop plan refuses a public RDP listener"
assert_contains "$actual" '不开放防火墙端口' \
    "remote desktop plan preserves the firewall boundary"
rm -rf -- "$remote_root"

temporary_root=$(mktemp -d)
mkdir -p "$temporary_root/bin"
cat > "$temporary_root/quick_start.sh" <<'EOF'
#!/usr/bin/env bash
touch "$VPS_1PANEL_MUST_NOT_EXECUTE"
EOF
checksum=$(shasum -a 256 "$temporary_root/quick_start.sh" | awk '{ print $1 }')
cat > "$temporary_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
destination=''
while (( $# > 0 )); do
    case $1 in
        -o) destination=$2; shift 2 ;;
        *) shift ;;
    esac
done
cp "$VPS_1PANEL_FIXTURE" "$destination"
EOF
chmod +x "$temporary_root/bin/curl"
marker="$temporary_root/executed"
actual=$(PATH="$temporary_root/bin:$PATH" \
    VPS_1PANEL_INSTALL_SHA256="$checksum" \
    VPS_1PANEL_FIXTURE="$temporary_root/quick_start.sh" \
    VPS_1PANEL_MUST_NOT_EXECUTE="$marker" \
    "$CLI" module run applications.1panel preflight)
assert_contains "$actual" '预检通过' "1Panel preflight verifies the pinned installer entry"
if [[ -e "$marker" ]]; then
    fail "1Panel preflight must not execute the installer"
else
    pass "1Panel preflight does not execute the installer"
fi

rm -rf -- "$temporary_root"
finish_tests
