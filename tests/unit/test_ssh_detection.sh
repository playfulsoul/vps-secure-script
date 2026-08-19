#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/ssh.sh
source "$PROJECT_ROOT/core/ssh.sh"

actual=$(vps_ssh_connection_port '198.51.100.7 50123 203.0.113.9 32876')
assert_eq '32876' "$actual" "current SSH session preserves its custom server port"

if vps_ssh_connection_port '198.51.100.7 50123 203.0.113.9 70000' >/dev/null; then
    fail "invalid SSH session port is rejected"
else
    pass "invalid SSH session port is rejected"
fi

vps_active_sshd_ports() {
    printf '%s\n' 32876 44000
}

vps_sshd_effective_ports() {
    printf '%s\n' 32876 44000
}

SSH_CONNECTION='198.51.100.7 50123 203.0.113.9 32876'
actual=$(vps_detect_ssh_ports | paste -sd, -)
assert_eq '32876,44000' "$actual" "all confirmed SSH ports are deduplicated and preserved"

vps_active_sshd_ports() {
    return 1
}

vps_sshd_effective_ports() {
    return 1
}

SSH_CONNECTION=''
if vps_require_ssh_ports >/dev/null; then
    fail "port detection does not fall back to port 22"
else
    pass "port detection does not fall back to port 22"
fi

finish_tests
