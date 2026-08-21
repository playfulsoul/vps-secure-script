#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
CLI="$PROJECT_ROOT/bin/vps"
MODULE="$PROJECT_ROOT/modules/builtin/diagnostics-external/module.sh"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

actual=$("$CLI" module run diagnostics.external status)
for label in 'YABS' 'Bench.sh' '流媒体解锁' 'NextTrace' '融合怪' 'IP 地址质量'; do
    assert_contains "$actual" "$label" "diagnostics catalog exposes $label"
done
assert_contains "$actual" 'SHA-256:' "diagnostics catalog shows pinned checksums"
assert_contains "$actual" '部分工具运行时仍会下载上游组件' \
    "diagnostics catalog explains the downstream trust boundary"

if command -v rg >/dev/null 2>&1; then
    mutable_url_found=$(rg -n "raw\.githubusercontent\.com/[^/]+/[^/]+/(main|master)/" "$MODULE" || true)
else
    mutable_url_found=$(grep -En "raw\.githubusercontent\.com/[^/]+/[^/]+/(main|master)/" "$MODULE" || true)
fi
if [[ -n "$mutable_url_found" ]]; then
    fail "diagnostic entry scripts must not use mutable main or master URLs"
else
    pass "diagnostic entry scripts use immutable commit URLs"
fi

actual=$(printf '6\n0\n0\n' | "$CLI")
assert_contains "$actual" '融合怪综合测试' "ordinary menu exposes Fusion"
assert_contains "$actual" 'NextTrace 回程路由测试' "ordinary menu exposes return-route testing"
assert_contains "$actual" '流媒体解锁检测' "ordinary menu exposes media testing"

temporary_root=$(mktemp -d)
mkdir -p "$temporary_root/bin"
cat > "$temporary_root/tool.sh" <<'EOF'
#!/usr/bin/env bash
touch "$VPS_DIAGNOSTIC_MUST_NOT_EXECUTE"
EOF
checksum=$(shasum -a 256 "$temporary_root/tool.sh" | awk '{ print $1 }')
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
cp "$VPS_DIAGNOSTIC_FIXTURE" "$destination"
EOF
chmod +x "$temporary_root/bin/curl"
marker="$temporary_root/executed"
actual=$(PATH="$temporary_root/bin:$PATH" \
    VPS_DIAGNOSTIC_URL=https://example.invalid/tool.sh \
    VPS_DIAGNOSTIC_SHA256="$checksum" \
    VPS_DIAGNOSTIC_FIXTURE="$temporary_root/tool.sh" \
    VPS_DIAGNOSTIC_MUST_NOT_EXECUTE="$marker" \
    "$CLI" module run diagnostics.external preflight yabs)
assert_contains "$actual" '预检通过' "diagnostic preflight verifies a catalog entry"
if [[ -e "$marker" ]]; then
    fail "diagnostic preflight must not execute third-party code"
else
    pass "diagnostic preflight does not execute third-party code"
fi
rm -rf -- "$temporary_root"

finish_tests
