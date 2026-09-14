#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
WORKFLOW="$PROJECT_ROOT/.github/workflows/ci.yml"

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

trigger_block=$(sed -n '/^on:$/,/^permissions:$/p' "$WORKFLOW")

assert_contains "$trigger_block" $'  push:\n    branches:\n      - main\n    tags:\n      - '\''v*'\''' \
    "push CI is limited to main and version tags"
assert_contains "$trigger_block" $'  pull_request:' \
    "pull requests trigger CI"
assert_contains "$trigger_block" $'  workflow_dispatch:' \
    "manual CI runs remain available"

push_block=$(sed -n '/^  push:$/,/^  pull_request:$/p' "$WORKFLOW")
push_branches=$(sed -n '/^    branches:$/,/^    tags:$/p' <<<"$push_block" | sed -n 's/^      - //p')
assert_eq 'main' "$push_branches" \
    "feature branch pushes do not duplicate pull request CI"

finish_tests
