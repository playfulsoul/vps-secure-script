#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VPS_PLATFORM_ROOT=$PROJECT_ROOT
export VPS_PLATFORM_ROOT

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/modules.sh
source "$PROJECT_ROOT/core/modules.sh"

actual=$(vps_module_list)
assert_contains "$actual" $'system.doctor\tSystem readiness doctor\t2.0.0-beta.1\tsystem\tbuiltin' \
    "module registry discovers the system doctor"
assert_contains "$actual" $'security.ssh\tOpenSSH access status\t2.0.0-beta.1\tsecurity\tbuiltin' \
    "module registry discovers the SSH module"
assert_contains "$actual" $'security.firewall\tHost firewall management\t2.0.0-beta.1\tsecurity\tbuiltin' \
    "module registry discovers the firewall module"
assert_contains "$actual" $'security.fail2ban\tFail2Ban SSH protection\t2.0.0-beta.1\tsecurity\tbuiltin' \
    "module registry discovers the Fail2Ban module"

manifest=$(vps_module_find security.ssh)
assert_contains "$manifest" '/modules/builtin/security-ssh/module.conf' \
    "module lookup resolves the expected manifest"

if vps_module_action_is_valid status; then
    pass "known module action is accepted"
else
    fail "known module action is accepted"
fi

if vps_module_action_is_valid preflight; then
    pass "read-only preflight module action is accepted"
else
    fail "read-only preflight module action is accepted"
fi

if vps_module_action_is_valid arbitrary-command; then
    fail "arbitrary module action is rejected"
else
    pass "arbitrary module action is rejected"
fi

invalid_manifest=$(mktemp)
printf '%s\n' \
    'id=test.invalid' \
    'name=Invalid entry test' \
    'version=1.0.0' \
    'category=test' \
    'entry=../outside.sh' \
    'trust=third-party' \
    'privilege=unprivileged' \
    'actions=status' > "$invalid_manifest"

if vps_validate_manifest "$invalid_manifest" >/dev/null 2>&1; then
    fail "manifest entry cannot escape its module directory"
else
    pass "manifest entry cannot escape its module directory"
fi
rm -f "$invalid_manifest"

if vps_module_declares_action "$(vps_module_find security.ssh)" status; then
    pass "registry accepts an action declared by the module"
else
    fail "registry accepts an action declared by the module"
fi

if vps_module_declares_action "$(vps_module_find security.ssh)" apply; then
    fail "registry rejects an undeclared module action"
else
    pass "registry rejects an undeclared module action"
fi

finish_tests
