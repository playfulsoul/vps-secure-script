#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/build_identity.sh
source "$PROJECT_ROOT/core/build_identity.sh"

temporary_root=$(mktemp -d)
source_root="$temporary_root/source"
evidence_root="$temporary_root/evidence"
mkdir -p "$source_root/subdir" "$evidence_root"
printf '%s\n' 'alpha' > "$source_root/subdir/example.txt"
ln -s subdir/example.txt "$source_root/example-link"

first=$(vps_calculate_build_id "$source_root")
second=$(vps_calculate_build_id "$source_root")
assert_eq "$first" "$second" \
    "unchanged candidate content receives a stable build identity"

printf '%s\n' 'beta' >> "$source_root/subdir/example.txt"
content_changed=$(vps_calculate_build_id "$source_root")
if [[ "$content_changed" == "$first" ]]; then
    fail "file content changes must change the build identity"
else
    pass "file content changes receive a different build identity"
fi

chmod 600 "$source_root/subdir/example.txt"
mode_changed=$(vps_calculate_build_id "$source_root")
if [[ "$mode_changed" == "$content_changed" ]]; then
    fail "file mode changes must change the build identity"
else
    pass "file mode changes receive a different build identity"
fi

rm "$source_root/example-link"
ln -s missing-target "$source_root/example-link"
link_changed=$(vps_calculate_build_id "$source_root")
if [[ "$link_changed" == "$mode_changed" ]]; then
    fail "symbolic-link target changes must change the build identity"
else
    pass "symbolic-link target changes receive a different build identity"
fi

vps_build_manifest "$source_root" "$evidence_root/BUILD_MANIFEST.sha256"
recorded="sha256-$(vps_build_sha256_file "$evidence_root/BUILD_MANIFEST.sha256")"
printf '%s\n' "$recorded" > "$source_root/BUILD_ID"
cp "$evidence_root/BUILD_MANIFEST.sha256" "$source_root/BUILD_MANIFEST.sha256"
actual=$(vps_verify_build_identity "$source_root")
assert_eq "$recorded" "$actual" \
    "recorded identity verifies against the candidate content"

printf '%s\n' 'tampered' >> "$source_root/subdir/example.txt"
if vps_verify_build_identity "$source_root" >/dev/null 2>&1; then
    fail "candidate tampering must invalidate the recorded build identity"
else
    pass "candidate tampering invalidates the recorded build identity"
fi

rm -rf -- "$temporary_root"
finish_tests
