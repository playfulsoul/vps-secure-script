#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

export VPS_PLATFORM_ROOT=$PROJECT_ROOT
export VPS_TRAFFIC_CONFIG="$TEST_ROOT/traffic-quota.conf"
export VPS_TRAFFIC_AS_OF_DATE=2026-03-15
source "$PROJECT_ROOT/modules/builtin/monitoring-vnstat/module.sh"

if traffic_arguments --interface eth0 --quota-gib 1000 --reset-day 31 \
    --warn-percent 80 --critical-percent 90; then
    pass "quota accepts a reset day up to 31"
else
    fail "quota accepts a reset day up to 31"
fi
if traffic_arguments --interface eth0 --quota-gb 3072 --reset-day 1 \
    --warn-percent 80 --critical-percent 90; then
    pass "quota accepts exact decimal GB and calendar-month reset"
else
    fail "quota accepts exact decimal GB and calendar-month reset"
fi
if traffic_arguments --interface eth0 --quota-gb 3072 --reset-day 1 \
    --warn-percent 80 --critical-percent >/dev/null 2>&1; then
    fail "quota rejects a missing option value"
else
    pass "quota rejects a missing option value"
fi
if traffic_arguments --interface eth0 --quota-gb 3072 --quota-gib 2861 --reset-day 1 \
    --warn-percent 80 --critical-percent 90 >/dev/null 2>&1; then
    fail "quota rejects ambiguous mixed units"
else
    pass "quota rejects ambiguous mixed units"
fi
if traffic_arguments --interface 'eth0;id' --quota-gib 1000 --reset-day 1 \
    --warn-percent 80 --critical-percent 90 >/dev/null 2>&1; then
    fail "quota rejects shell metacharacters in interface"
else
    pass "quota rejects shell metacharacters in interface"
fi
if traffic_arguments --interface eth0 --quota-gib 1000 --reset-day 1 \
    --warn-percent 90 --critical-percent 80 >/dev/null 2>&1; then
    fail "quota rejects reversed thresholds"
else
    pass "quota rejects reversed thresholds"
fi

cat > "$TEST_ROOT/vnstat.json" <<'EOF'
{"vnstatversion":"2.11","jsonversion":"2","interfaces":[{"name":"eth0","created":{"date":{"year":2026,"month":2,"day":1}},"traffic":{"day":[{"date":{"year":2026,"month":2,"day":28},"rx":536870912,"tx":536870912},{"date":{"year":2026,"month":3,"day":1},"rx":1073741824,"tx":1073741824}]}}]}
EOF
actual=$(python3 "$PROJECT_ROOT/modules/builtin/monitoring-vnstat/traffic.py" \
    --interface eth0 --quota-gib 2 --reset-day 31 --warn-percent 80 \
    --critical-percent 90 < "$TEST_ROOT/vnstat.json")
assert_contains "$actual" '2026-02-28 至 2026-03-31' \
    "quota clamps a 31st reset to February's final day"
assert_contains "$actual" '合计: 3.00 / 2 GiB（150.0%）' \
    "quota sums upload and download within the exact billing cycle"
assert_contains "$actual" '数据状态: 已覆盖账期起点' \
    "quota recognizes a cycle beginning on the clamped reset day"
actual=$(python3 "$PROJECT_ROOT/modules/builtin/monitoring-vnstat/traffic.py" \
    --interface eth0 --quota-gb 3 --reset-day 1 --warn-percent 80 \
    --critical-percent 90 < "$TEST_ROOT/vnstat.json")
assert_contains "$actual" '合计: 2.15 / 3 GB（71.6%）' \
    "quota calculates decimal GB from bytes without GiB inflation"
assert_contains "$actual" '下载: 1.07 GB；上传: 1.07 GB' \
    "quota reports component traffic in the selected decimal unit"
actual=$(sed 's/"day":28/"day":27/' "$TEST_ROOT/vnstat.json" | \
    python3 "$PROJECT_ROOT/modules/builtin/monitoring-vnstat/traffic.py" \
    --interface eth0 --quota-gib 2 --reset-day 31 --warn-percent 80 \
    --critical-percent 90)
assert_contains "$actual" '数据状态: 不完整' \
    "quota marks a cycle whose first daily record starts late"

if sed 's/"jsonversion":"2"/"jsonversion":"1"/' "$TEST_ROOT/vnstat.json" | \
    python3 "$PROJECT_ROOT/modules/builtin/monitoring-vnstat/traffic.py" \
    --interface eth0 --quota-gib 2 --reset-day 31 --warn-percent 80 \
    --critical-percent 90 >/dev/null 2>&1; then
    fail "quota rejects legacy vnStat JSON units"
else
    pass "quota rejects legacy vnStat JSON units"
fi

# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ncat "$VPS_TEST_VNSTAT_JSON"\n' > "$TEST_ROOT/bin/vnstat"
chmod 755 "$TEST_ROOT/bin/vnstat"
export VPS_TEST_VNSTAT_JSON="$TEST_ROOT/vnstat.json"
export PATH="$TEST_ROOT/bin:$PATH"
vps_require_root() { return 0; }
traffic_apply --interface eth0 --quota-gib 2 --reset-day 31 \
    --warn-percent 80 --critical-percent 90 >/dev/null
assert_file_exists "$VPS_TRAFFIC_CONFIG" "quota configuration is saved locally"
mode=$(stat -c %a "$VPS_TRAFFIC_CONFIG" 2>/dev/null || stat -f %Lp "$VPS_TRAFFIC_CONFIG")
assert_eq '600' "$mode" "quota configuration is root-only"
actual=$(traffic_status)
assert_contains "$actual" '网卡: eth0' "quota status reads saved local configuration"
traffic_apply --interface eth0 --quota-gb 3072 --reset-day 1 \
    --warn-percent 80 --critical-percent 90 >/dev/null
assert_contains "$(<"$VPS_TRAFFIC_CONFIG")" 'quota_gb=3072' \
    "quota saves an exact decimal GB allowance"
actual=$(traffic_status)
assert_contains "$actual" '/ 3072 GB' "quota status retains decimal GB units"

printf 'unowned=1\n' > "$VPS_TRAFFIC_CONFIG"
chmod 600 "$VPS_TRAFFIC_CONFIG"
if traffic_apply --interface eth0 --quota-gib 2 --reset-day 31 \
    --warn-percent 80 --critical-percent 90 >/dev/null 2>&1; then
    fail "quota refuses to overwrite an unowned configuration"
else
    pass "quota refuses to overwrite an unowned configuration"
fi
assert_eq 'unowned=1' "$(<"$VPS_TRAFFIC_CONFIG")" \
    "quota preserves an unowned configuration unchanged"

finish_tests
