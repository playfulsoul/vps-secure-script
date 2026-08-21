#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/data"

printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "PING 1.1.1.1" "5 packets transmitted, 4 received, 20% packet loss, time 4004ms" "rtt min/avg/max/mdev = 10.000/20.500/30.000/2.000 ms"' \
    > "$TEST_ROOT/bin/ping"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "default via 192.0.2.1 dev test0\n"' > "$TEST_ROOT/bin/ip"
# The single-quoted fixture must preserve ${1:-} for the generated script.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == is-active ]]; then printf "inactive\n"; exit 3; fi' \
    'exit 0' > "$TEST_ROOT/bin/systemctl"
chmod +x "$TEST_ROOT/bin/ping" "$TEST_ROOT/bin/ip" "$TEST_ROOT/bin/systemctl"
printf '%s\n' 'target=1.1.1.1' 'interval=60' 'retention_days=30' > "$TEST_ROOT/config"

PATH="$TEST_ROOT/bin:$PATH" \
VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
VPS_MODULE_DIR="$PROJECT_ROOT/modules/builtin/monitoring-network" \
VPS_MONITOR_CONFIG="$TEST_ROOT/config" \
VPS_MONITOR_DATA_DIR="$TEST_ROOT/data" \
    "$PROJECT_ROOT/modules/builtin/monitoring-network/module.sh" collect

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

assert_file_exists "$TEST_ROOT/data/metrics.tsv" "network collector creates its metrics store"
actual=$(tail -n 1 "$TEST_ROOT/data/metrics.tsv")
assert_contains "$actual" $'1.1.1.1\t5\t4\t20\t20.500' \
    "network collector records latency and packet loss"

rm -f "$TEST_ROOT/config"
PATH="$TEST_ROOT/bin:$PATH" \
VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
VPS_MODULE_DIR="$PROJECT_ROOT/modules/builtin/monitoring-network" \
VPS_MONITOR_CONFIG="$TEST_ROOT/config" \
VPS_MONITOR_DATA_DIR="$TEST_ROOT/data" \
    "$PROJECT_ROOT/modules/builtin/monitoring-network/module.sh" collect --target 9.9.9.9
actual=$(tail -n 1 "$TEST_ROOT/data/metrics.tsv")
assert_contains "$actual" $'9.9.9.9\t5\t4\t20\t20.500' \
    "one-time network collection works without prior configuration"

actual=$(PATH="$TEST_ROOT/bin:$PATH" \
    VPS_PLATFORM_ROOT="$PROJECT_ROOT" \
    VPS_MODULE_DIR="$PROJECT_ROOT/modules/builtin/monitoring-network" \
    VPS_MONITOR_CONFIG="$TEST_ROOT/config" \
    VPS_MONITOR_DATA_DIR="$TEST_ROOT/data" \
    "$PROJECT_ROOT/modules/builtin/monitoring-network/module.sh" status)
assert_contains "$actual" '平均延迟：20.500 ms' "network status renders a human-readable latency"
assert_contains "$actual" '丢包率：20%' "network status renders a human-readable loss rate"
assert_contains "$actual" '网络状态：存在丢包' "network status explains the measured quality"
assert_contains "$actual" '定时器状态: inactive' "network status reports an inactive timer once"
if [[ "$actual" == *$'定时器状态: inactive\ninactive'* ]]; then
    fail "network status does not duplicate an inactive timer state"
else
    pass "network status does not duplicate an inactive timer state"
fi

finish_tests
