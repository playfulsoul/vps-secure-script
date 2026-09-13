#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VERSION=2.0.0-beta.2
VPS_PLATFORM_ROOT=$PROJECT_ROOT

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/update.sh
source "$PROJECT_ROOT/core/update.sh"

if vps_version_is_newer 2.0.0-beta.3 2.0.0-beta.2; then
    pass "update comparison accepts a newer beta"
else
    fail "update comparison must accept a newer beta"
fi

if vps_version_is_newer 2.0.0 2.0.0-beta.2; then
    pass "update comparison promotes a beta to stable"
else
    fail "stable release must be newer than its beta"
fi

if vps_version_is_newer 2.0.0-beta.1 2.0.0-beta.2; then
    fail "update comparison must reject an older beta"
else
    pass "update comparison rejects an older beta"
fi

relation=$(vps_release_identity_relation 2.0.0-beta.2 sha256-b \
    2.0.0-beta.2 sha256-a)
assert_eq 'different-build' "$relation" \
    "update comparison distinguishes different builds of the same semantic version"

relation=$(vps_release_identity_relation 2.0.0-beta.2 sha256-a \
    2.0.0-beta.2 sha256-a)
assert_eq 'same' "$relation" \
    "update comparison recognizes an identical version and build"

release_response=$(mktemp)
printf '%s\n' \
    '{"tag_name":"v2.0.0-beta.2","prerelease":true}' \
    '{"tag_name":"v2.0.0-beta.3","prerelease":true}' > "$release_response"
actual=$(vps_update_extract_version "$release_response")
assert_eq '2.0.0-beta.3' "$actual" "GitHub release response selects the newest validated version"
rm -f "$release_response"

release_response=$(mktemp)
build_digest=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
printf '%s\n' \
    "{\"name\":\"vps-secure-platform-2.0.0-beta.3-build.sha256-$build_digest.tar.gz\"}" \
    > "$release_response"
actual=$(vps_update_extract_build_id "$release_response" 2.0.0-beta.3)
assert_eq "sha256-$build_digest" "$actual" \
    "release metadata exposes the build identity used in the archive name"
rm -f "$release_response"

update_cache=$(mktemp -d)
VPS_UPDATE_CACHE_DIR=$update_cache
VERSION=2.0.0-beta.2
BUILD_ID=sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf '%s\n' \
    "{\"tag_name\":\"v2.0.0-beta.2\",\"name\":\"vps-secure-platform-2.0.0-beta.2-build.sha256-$build_digest.tar.gz\"}" \
    > "$update_cache/release.json"
actual=$(vps_update_check no 2>&1 || true)
assert_contains "$actual" '语义版本相同，但发布构建不同' \
    "update check reports a same-version build mismatch instead of claiming equality"
rm -rf -- "$update_cache"

release_response=$(mktemp)
printf '%s\n' \
    '{"tag_name":"v2.0.0-beta.3","prerelease":true}' \
    '{"tag_name":"v2.0.0","prerelease":false}' > "$release_response"
actual=$(vps_update_extract_version "$release_response")
assert_eq '2.0.0' "$actual" "release selection treats stable as newer than its prerelease"
rm -f "$release_response"

invalid_response=$(mktemp)
# shellcheck disable=SC2016
printf '%s\n' '{"tag_name":"$(touch /tmp/unsafe)"}' > "$invalid_response"
if vps_update_extract_version "$invalid_response" >/dev/null 2>&1; then
    fail "update metadata must reject non-version content"
else
    pass "update metadata rejects non-version content"
fi
rm -f "$invalid_response"

finish_tests
