#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/target"
touch "$TEST_ROOT/fstab"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/bin/swapon"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$TEST_ROOT/bin/mkswap"
cat > "$TEST_ROOT/bin/df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
    'Filesystem 1048576-blocks Used Available Capacity Mounted on' \
    "fake 4096 1024 ${VPS_TEST_AVAILABLE_MB:-2048} 25% /"
EOF
chmod +x "$TEST_ROOT/bin/swapon" "$TEST_ROOT/bin/mkswap" "$TEST_ROOT/bin/df"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

actual=$(PATH="$TEST_ROOT/bin:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_STATE_DIR="$TEST_ROOT/state" \
    VPS_SWAP_FILE="$TEST_ROOT/target/swapfile" \
    VPS_FSTAB_FILE="$TEST_ROOT/fstab" \
    VPS_TEST_AVAILABLE_MB=2048 \
    "$PROJECT_ROOT/modules/builtin/system-swap/module.sh" plan --size 1G)
assert_contains "$actual" '至少保留 256 MB' "Swap plan preserves a disk-space safety margin"

actual=$(PATH="$TEST_ROOT/bin:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_STATE_DIR="$TEST_ROOT/state" \
    VPS_SWAP_FILE="$TEST_ROOT/target/swapfile" \
    VPS_FSTAB_FILE="$TEST_ROOT/fstab" \
    VPS_TEST_AVAILABLE_MB=1200 \
    "$PROJECT_ROOT/modules/builtin/system-swap/module.sh" plan --size 1G 2>&1 || true)
assert_contains "$actual" '磁盘空间不足' "Swap plan rejects a choice that would consume the safety margin"

finish_tests
