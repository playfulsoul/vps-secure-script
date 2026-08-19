#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/.." && pwd)
failures=0

while IFS= read -r script; do
    if bash -n "$script"; then
        printf 'ok - bash syntax: %s\n' "${script#"$PROJECT_ROOT/"}"
    else
        printf 'not ok - bash syntax: %s\n' "${script#"$PROJECT_ROOT/"}" >&2
        failures=$((failures + 1))
    fi
done < <(find "$PROJECT_ROOT" -type f -name '*.sh' -not -path '*/.git/*' | sort)

if command -v shellcheck >/dev/null 2>&1; then
    while IFS= read -r script; do
        if shellcheck -x "$script"; then
            printf 'ok - shellcheck: %s\n' "${script#"$PROJECT_ROOT/"}"
        else
            failures=$((failures + 1))
        fi
    done < <(find "$PROJECT_ROOT" -type f -name '*.sh' -not -path '*/legacy/*' -not -path '*/.git/*' | sort)
else
    printf 'skip - shellcheck is not installed\n'
fi

if (( failures > 0 )); then
    exit 1
fi
