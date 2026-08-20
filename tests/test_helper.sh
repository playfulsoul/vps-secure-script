#!/usr/bin/env bash

set -u

TEST_FAILURES=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    TEST_FAILURES=$((TEST_FAILURES + 1))
}

pass() {
    printf 'ok - %s\n' "$1"
}

assert_eq() {
    local expected=$1
    local actual=$2
    local message=$3

    if [[ "$expected" == "$actual" ]]; then
        pass "$message"
    else
        fail "$message (expected: $expected, actual: $actual)"
    fi
}

assert_file_exists() {
    local path=$1
    local message=$2

    if [[ -f "$path" ]]; then
        pass "$message"
    else
        fail "$message (missing: $path)"
    fi
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local message=$3

    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (missing text: $needle)"
    fi
}

finish_tests() {
    if (( TEST_FAILURES > 0 )); then
        printf '%s test(s) failed\n' "$TEST_FAILURES" >&2
        return 1
    fi

    return 0
}
