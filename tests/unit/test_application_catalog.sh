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
