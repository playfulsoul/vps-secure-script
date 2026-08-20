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
chmod +x "$TEST_ROOT/bin/ping" "$TEST_ROOT/bin/ip"
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

finish_tests
