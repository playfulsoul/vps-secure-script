#!/usr/bin/env bash

set -u
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"
cat > "$test_root/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$VPS_TEST_APT_LOG"
if [[ "$*" == *update* && "$VPS_TEST_APT_FAILURE" == yes ]]; then
    printf 'W: Failed to fetch repository: EXPKEYSIG\n' >&2
    # apt-get normally permits reusing old indexes. Strict mode must reject it.
    [[ "$*" != *'APT::Update::Error-Mode=any'* ]] || exit 100
fi
MOCK
chmod +x "$test_root/bin/apt-get"
run_packages() {
    PATH="$test_root/bin:$PATH" VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_TEST_APT_LOG="$test_root/apt.log" VPS_TEST_APT_FAILURE="$1" \
    bash -c '
        source "$VPS_PLATFORM_ROOT/modules/builtin/system-packages/module.sh" plan >/dev/null
        vps_require_root() { return 0; }
        vps_apt_locks_available() { return 0; }
        packages_apply
    '
}
actual=$(run_packages yes 2>&1)
assert_eq 40 "$?" 'repository signature failure stops package maintenance'
assert_contains "$actual" '软件源索引更新失败' 'repository failure has actionable wording'
if [[ "$actual" == *'软件包索引和常规升级已完成'* ]] || grep -q '^upgrade' "$test_root/apt.log"; then
    fail 'failed index update must neither upgrade nor report success'
else
    pass 'failed index update neither upgrades nor reports success'
fi
: > "$test_root/apt.log"
actual=$(run_packages no 2>&1)
assert_eq 0 "$?" 'successful index update permits normal upgrade'
assert_contains "$actual" '软件包索引和常规升级已完成' 'success is reported after both operations complete'
assert_eq '-o APT::Update::Error-Mode=any update
upgrade -y' "$(cat "$test_root/apt.log")" 'strict update precedes normal upgrade'
finish_tests
