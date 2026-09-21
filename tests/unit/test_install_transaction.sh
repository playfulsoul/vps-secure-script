#!/usr/bin/env bash
# shellcheck disable=SC2329
set -u
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/install_transaction.sh
source "$PROJECT_ROOT/core/install_transaction.sh"
scratch=$(mktemp -d)
scratch=$(cd "$scratch" && pwd -P)

fixture() {
    local dir=$1 version=$2
    mkdir -p "$dir/bin" "$dir/core" "$dir/modules"
    printf '%s\n' "$version" > "$dir/VERSION"
    cat > "$dir/bin/vps" <<'EOF'
#!/usr/bin/env bash
entry=$0
[[ ! -L "$entry" ]] || entry=$(readlink "$entry")
root=$(cd "$(dirname "$entry")/.." && pwd)
printf 'vps-secure %s\n' "$(<"$root/VERSION")"
EOF
    chmod 755 "$dir/bin/vps"
}
fixture "$scratch/new" 2.0.1
new_case() {
    case_root="$scratch/$1"
    mkdir -p "$case_root/bin"
    fixture "$case_root/lib" 2.0.0
    ln -s "$case_root/lib/bin/vps" "$case_root/bin/vps"
}
assert_old() {
    assert_eq 'vps-secure 2.0.0' "$("$case_root/bin/vps" --version)" "$1"
}

new_case normal
vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new" > "$case_root/out"
assert_eq 'vps-secure 2.0.1' "$("$case_root/bin/vps" --version)" 'successful switch verifies the new entry'
previous=$(find "$case_root" -maxdepth 1 -type d -name 'lib.backup.*' | head -n 1)
vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$previous" > "$case_root/restore"
assert_old 'restoration switches back to a runnable old version'
assert_file_exists "$previous/bin/vps" 'restoration preserves its original backup'
assert_eq 2 "$(find "$case_root" -maxdepth 1 -name 'lib.backup.*' | wc -l | tr -d ' ')" 'rapid repeated operations retain separate backups'

for failure in copy move-old move-new link; do
    new_case "$failure"
    (
        cp() { [[ "$failure" != copy ]] || return 1; command cp "$@"; }
        mv() {
            if [[ "$failure" == move-old && "$2" == "$case_root/lib" ]]; then return 1; fi
            if [[ "$failure" == move-new && "$2" == */candidate ]]; then return 1; fi
            command mv "$@"
        }
        ln() {
            if [[ "$failure" == link && ! -e "$case_root/injected" ]]; then
                touch "$case_root/injected"; return 1
            fi
            command ln "$@"
        }
        vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new"
    ) > "$case_root/result" 2>&1
    assert_eq 40 "$?" "$failure failure is reported"
    assert_old "$failure failure preserves the old usable entry"
done

new_case compensation
(
    ln() { return 1; }
    mv() { [[ "$2" != *'.backup.'* ]] || return 1; command mv "$@"; }
    vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new"
) > "$case_root/result" 2>&1
assert_eq 60 "$?" 'failed compensation is reported distinctly'
assert_contains "$(<"$case_root/result")" '恢复也未完成' 'failed compensation provides explicit guidance'
assert_file_exists "$case_root/lib.operation-lock/transaction" 'failed compensation retains transaction lock and evidence'
assert_eq 1 "$(find "$case_root" -path '*backup.*/bin/vps' | wc -l | tr -d ' ')" 'failed compensation retains the recoverable old backup'

new_case collision
(
    date() { printf 'FIXED\n'; }
    collision_copy() {
        mkdir "$case_root/lib.backup.FIXED.000000001"
        printf 'keep\n' > "$case_root/lib.backup.FIXED.000000001/marker"
        vps_tx_copy_backup "$@"
    }
    vps_install_transaction "$case_root/lib" "$case_root/bin/vps" collision_copy "$scratch/new"
) > "$case_root/result" 2>&1
assert_eq 40 "$?" 'existing backup destination is rejected'
assert_old 'backup collision leaves installation untouched'
assert_eq keep "$(<"$case_root/lib.backup.FIXED.000000001/marker")" 'backup collision preserves existing contents'

new_case corrupt
fixture "$case_root/bad" 2.0.2
chmod 600 "$case_root/bad/bin/vps"
vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$case_root/bad" > "$case_root/result" 2>&1
assert_eq 40 "$?" 'damaged backup is rejected before switch'
assert_old 'damaged backup leaves current entry usable'

vps_tx_check_install "$scratch/new" 9.9.9 >/dev/null 2>&1
assert_eq 40 "$?" 'verification rejects an unexpected installed version'
vps_tx_check_install "$scratch/new" 2.0.1 sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1
assert_eq 40 "$?" 'verification rejects a missing expected build identity'
fixture "$scratch/bad-build" 2.0.1
printf '%s\n' sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$scratch/bad-build/BUILD_ID"
vps_tx_check_install "$scratch/bad-build" >/dev/null 2>&1
assert_eq 40 "$?" 'verification rejects CLI output inconsistent with its build identity'

new_case term
(
    mv() {
        command mv "$@" || return $?
        if [[ "$2" == */candidate ]]; then bash -c 'kill -TERM "$PPID"'; fi
    }
    vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new"
) > "$case_root/result" 2>&1
assert_eq 143 "$?" 'TERM after candidate rename returns signal status'
assert_old 'TERM after candidate rename compensates the switch'

new_case concurrency
(
    held_copy() {
        touch "$case_root/ready"
        for ((i=0; i<100; i++)); do
            [[ ! -e "$case_root/release" ]] || break
            sleep 0.05
        done
        vps_tx_copy_backup "$@"
    }
    vps_install_transaction "$case_root/lib" "$case_root/bin/vps" held_copy "$scratch/new"
) > "$case_root/first" 2>&1 &
worker=$!
for ((i=0; i<100; i++)); do [[ ! -e "$case_root/ready" ]] || break; sleep 0.05; done
vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new" > "$case_root/second" 2>&1
assert_eq 30 "$?" 'concurrent install or restore is rejected'
touch "$case_root/release"
wait "$worker"
assert_eq 0 "$?" 'original lock holder completes normally'

new_case stale
mkdir "$case_root/lib.operation-lock"
printf 'interrupted-transaction\n' > "$case_root/lib.operation-lock/transaction"
vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new" > "$case_root/result" 2>&1
assert_eq 30 "$?" 'unfinished operation is detected on next attempt'
assert_old 'unfinished operation is not automatically overwritten'
assert_contains "$(<"$case_root/result")" '上次操作中断' 'unfinished operation gives actionable diagnosis'

new_case killed
(
    kill_copy() { bash -c 'kill -KILL "$PPID"'; }
    vps_install_transaction "$case_root/lib" "$case_root/bin/vps" kill_copy "$scratch/new"
) > "$case_root/first" 2>&1
assert_eq 137 "$?" 'SIGKILL fixture cannot run compensation traps'
vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new" > "$case_root/second" 2>&1
assert_eq 30 "$?" 'real SIGKILL leaves a lock recognized on next attempt'
assert_old 'SIGKILL during preparation preserves the old entry'

new_case same_second
(
    date() { printf 'FIXED\n'; }
    vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new" &&
    vps_install_transaction "$case_root/lib" "$case_root/bin/vps" vps_tx_copy_backup "$scratch/new"
) > "$case_root/result" 2>&1
assert_eq 0 "$?" 'same-second installs succeed without backup nesting'
assert_file_exists "$case_root/lib.backup.FIXED.000000001/VERSION" 'first same-second backup is retained'
assert_file_exists "$case_root/lib.backup.FIXED.000000002/VERSION" 'second same-second backup sorts after first'

# Exercise failures in the real installer, not only the shared switch helper.
mkdir "$scratch/wrappers"
for tool in cp chmod find; do
    cat > "$scratch/wrappers/$tool" <<'EOF'
#!/usr/bin/env bash
name=${0##*/}
for arg in "$@"; do
    if [[ "$name" == "$VPS_TEST_FAIL_TOOL" && "$arg" == *'/candidate/'* ]]; then exit 1; fi
done
case $name in
    cp) exec /bin/cp "$@" ;;
    chmod) exec /bin/chmod "$@" ;;
    find) exec /usr/bin/find "$@" ;;
esac
EOF
    chmod 755 "$scratch/wrappers/$tool"
done
for tool in cp chmod find; do
    new_case "installer-$tool"
    PATH="$scratch/wrappers:$PATH" VPS_TEST_FAIL_TOOL="$tool" \
        VPS_INSTALL_ROOT="$case_root/lib" VPS_BIN_DIR="$case_root/bin" \
        "$PROJECT_ROOT/install.sh" > "$case_root/result" 2>&1
    assert_eq 40 "$?" "real installer rejects $tool failure"
    assert_old "real installer $tool failure preserves current entry"
done

printf 'Fault injection evidence: %s\n' "$scratch"
finish_tests
