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

if vps_version_is_newer 2.0.0-beta.6.1 2.0.0-beta.6; then
    pass "update comparison accepts the beta.6.1 hotfix over beta.6"
else
    fail "beta.6 clients must recognize beta.6.1 as newer"
fi

release_response=$(mktemp)
printf '%s\n' \
    '{"tag_name":"v2.0.0-beta.2","prerelease":true}' \
    '{"tag_name":"v2.0.0-beta.3","prerelease":true}' > "$release_response"
actual=$(vps_update_extract_version "$release_response")
assert_eq '2.0.0-beta.3' "$actual" "GitHub release response selects the newest validated version"
rm -f "$release_response"

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

temporary_root=$(mktemp -d)
fake_bin="$temporary_root/bin"
mkdir -p "$fake_bin" "$temporary_root/cache"

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
output=''
max_time=''
while (( $# > 0 )); do
    case $1 in
        -o) output=$2; shift 2 ;;
        --max-time) max_time=$2; shift 2 ;;
        *) shift ;;
    esac
done
count_file="$VPS_TEST_ROOT/metadata-count"
count=0
[[ ! -r "$count_file" ]] || count=$(<"$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf '%s\n' "$max_time" >> "$VPS_TEST_ROOT/metadata-max-times"
if (( count < 3 )); then
    printf '%s\n' 'curl: (28) Operation timed out after 5000 milliseconds with 9836 out of 50385 bytes received' >&2
    return 28 2>/dev/null || exit 28
fi
printf '%s\n' '{"tag_name":"v2.0.0-beta.3","prerelease":true}' > "$output"
EOF
chmod +x "$fake_bin/curl"

actual=$(PATH="$fake_bin:$PATH" VPS_TEST_ROOT="$temporary_root" \
    VPS_UPDATE_CACHE_DIR="$temporary_root/cache" VPS_UPDATE_DOWNLOAD_RETRY_DELAY=0 \
    vps_update_fetch_version yes 2>"$temporary_root/metadata-errors")
assert_eq '2.0.0-beta.3' "$actual" "explicit metadata check recovers from two five-second timeout failures"
assert_contains "$(<"$temporary_root/metadata-errors")" '9836 out of 50385 bytes received' \
    "metadata retry test reproduces the reported partial-response timeout"
assert_eq '3' "$(<"$temporary_root/metadata-count")" "explicit metadata check uses bounded retries"
metadata_timeouts_valid=yes
while IFS= read -r configured_timeout; do
    if (( configured_timeout <= 5 || configured_timeout > 30 )); then
        metadata_timeouts_valid=no
    fi
done < "$temporary_root/metadata-max-times"
assert_eq yes "$metadata_timeouts_valid" \
    "explicit metadata checks use the longer bounded total timeout"

rm -f "$temporary_root/metadata-count" "$temporary_root/metadata-max-times"
if PATH="$fake_bin:$PATH" VPS_TEST_ROOT="$temporary_root" \
    VPS_UPDATE_CACHE_DIR="$temporary_root/cache-failure" VPS_UPDATE_DOWNLOAD_RETRY_DELAY=0 \
    vps_update_fetch_version no >/dev/null 2>&1; then
    fail "background metadata fixture should time out"
else
    pass "background metadata check tolerates a simulated five-second timeout"
fi
if PATH="$fake_bin:$PATH" VPS_TEST_ROOT="$temporary_root" \
    VPS_UPDATE_CACHE_DIR="$temporary_root/cache-failure" VPS_UPDATE_DOWNLOAD_RETRY_DELAY=0 \
    vps_update_fetch_version no >/dev/null 2>&1; then
    fail "background metadata failure cache should not report a version"
elif [[ "$(<"$temporary_root/metadata-count")" == 1 ]]; then
    pass "background metadata failure cooldown avoids blocking every menu open"
else
    fail "background metadata failure cooldown repeated the network request"
fi

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
output=''
resume=no
while (( $# > 0 )); do
    case $1 in
        -o) output=$2; shift 2 ;;
        --continue-at) resume=yes; shift 2 ;;
        *) shift ;;
    esac
done
count_file="$VPS_TEST_ROOT/asset-count"
count=0
[[ ! -r "$count_file" ]] || count=$(<"$count_file")
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if (( count == 1 )); then
    existing_size=0
    [[ ! -e "$output" ]] || existing_size=$(wc -c < "$output" | tr -d ' ')
    printf '%s\n' "$existing_size" > "$VPS_TEST_ROOT/asset-initial-size"
    head -c 9836 "$VPS_TEST_ROOT/release.fixture" > "$output"
    exit 28
fi
[[ "$resume" == yes ]] || exit 90
offset=$(wc -c < "$output" | tr -d ' ')
dd if="$VPS_TEST_ROOT/release.fixture" bs=1 skip="$offset" 2>/dev/null >> "$output"
EOF
chmod +x "$fake_bin/curl"
head -c 50385 /dev/zero | tr '\0' x > "$temporary_root/release.fixture"
printf '%s\n' 'untrusted old partial data' > "$temporary_root/release.tar.gz.part"
PATH="$fake_bin:$PATH" VPS_TEST_ROOT="$temporary_root" \
    VPS_UPDATE_DOWNLOAD_ATTEMPTS=2 VPS_UPDATE_DOWNLOAD_RETRY_DELAY=0 \
    vps_update_download_asset https://example.invalid/release.tar.gz \
    "$temporary_root/release.tar.gz" 300 yes >/dev/null 2>&1
assert_eq '50385' "$(wc -c < "$temporary_root/release.tar.gz" | tr -d ' ')" \
    "release asset resumes after an interrupted 9836-of-50385-byte transfer"
assert_eq '0' "$(<"$temporary_root/asset-initial-size")" \
    "release download discards an old partial file before starting"
assert_eq "$(shasum -a 256 "$temporary_root/release.fixture" | awk '{ print $1 }')" \
    "$(shasum -a 256 "$temporary_root/release.tar.gz" | awk '{ print $1 }')" \
    "resumed release asset contains the complete original bytes"

rm -rf -- "$temporary_root"

finish_tests
