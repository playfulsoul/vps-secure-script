#!/usr/bin/env bash
# Test doubles are invoked indirectly by the loaded module functions.
# shellcheck disable=SC2329
set -eu
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
source "$PROJECT_ROOT/tests/test_helper.sh"
export VPS_PLATFORM_ROOT=$PROJECT_ROOT
eval "$(sed '/^case ${1:-} in/,$d' "$PROJECT_ROOT/modules/builtin/security-ssh/module.sh")"
root=$(mktemp -d)
root=$(cd "$root" && pwd -P)
trap 'rm -rf -- "$root"' EXIT
export VPS_STATE_DIR
fixture() {
    VPS_STATE_DIR=$root/$1/state
    VPS_SSH_KEY_HOME=$root/$1/home
    mkdir -p "$VPS_SSH_KEY_HOME"
    target=$VPS_SSH_KEY_HOME/.ssh/authorized_keys
}
ssh_key_passwd_record() { printf 'tester:x:%s:%s::%s:/bin/bash\n' "${TEST_UID:-$(id -u)}" "$(id -g)" "$VPS_SSH_KEY_HOME"; }
vps_require_root() { return 0; }
ssh_key_download() { printf 'ssh-ed25519 AAAAnew imported\n' > "$1"; }
ssh_key_show_fingerprints() { return 0; }
expect_failure() {
    local label=$1
    shift
    if "$@" > "$root/failure.log" 2>&1; then fail "$label"; else pass "$label"; fi
}
same() {
    if cmp -s "$1" "$2"; then pass "$3"; else fail "$3"; fi
}
fixture absent_later
ssh_key_configure --github test --user tester
printf '# later\n\nssh-ed25519 AAAAlater later\n' > "$root/later"
cat "$root/later" >> "$target"
ssh_key_rollback
same "$target" "$root/later" 'rollback preserves later keys, comments and blank lines byte-for-byte'
printf 'ssh-ed25519 AAAAnew imported\n' >> "$target"
cp "$target" "$root/repeated"
ssh_key_rollback
same "$target" "$root/repeated" 'repeat rollback does not remove a reintroduced key'

fixture existing_later
mkdir "$VPS_SSH_KEY_HOME/.ssh"
printf '# original\n\nrestrict ssh-ed25519 AAAAold old\n' > "$target"
cp "$target" "$root/original"
ssh_key_configure --github test --user tester
cat "$root/later" >> "$target"
cat "$root/original" "$root/later" > "$root/expected"
ssh_key_rollback
same "$target" "$root/expected" 'existing file retains options, comments and later additions'

fixture identical
mkdir "$VPS_SSH_KEY_HOME/.ssh"
printf 'command="echo hello",restrict ssh-ed25519 AAAAnew old comment\n\n' > "$target"
cp "$target" "$root/expected"
ssh_key_configure --github test --user tester
ssh_key_verify
same "$target" "$root/expected" 'preexisting key material keeps original restrictions without duplicate'
ssh_key_rollback
same "$target" "$root/expected" 'rollback does not remove preexisting matching key'

fixture comment_key
mkdir "$VPS_SSH_KEY_HOME/.ssh"
printf 'ssh-ed25519 AAAAold comment ssh-ed25519 AAAAnew\n' > "$target"
ssh_key_configure --github test --user tester
assert_contains "$(cat "$target")" 'AAAAnew imported' 'key text in a comment is not mistaken for authorization'

fixture missing_newline
mkdir "$VPS_SSH_KEY_HOME/.ssh"
printf '# no trailing newline' > "$target"
cp "$target" "$root/expected"
ssh_key_configure --github test --user tester
ssh_key_rollback
same "$target" "$root/expected" 'unchanged import rollback restores missing final newline'

fixture absent_empty
ssh_key_configure --github test --user tester
ssh_key_rollback
if [[ ! -e "$target" ]]; then pass 'originally absent file removed only when empty'; else fail 'empty file removal'; fi

fixture edited
ssh_key_configure --github test --user tester
printf 'restrict ssh-ed25519 AAAAnew changed\n# new\n\n' > "$target"
cp "$target" "$root/expected"
ssh_key_rollback
same "$target" "$root/expected" 'edited imported authorization is not owned and stays intact'

fixture duplicate
ssh_key_configure --github test --user tester
cat "$target" > "$root/expected"
cat "$root/expected" >> "$target"
cp "$target" "$root/expected"
ssh_key_rollback
same "$target" "$root/expected" 'ambiguous duplicate authorizations are preserved'

fixture removed
ssh_key_configure --github test --user tester
printf '# externally removed\n' > "$target"
cp "$target" "$root/expected"
ssh_key_rollback
same "$target" "$root/expected" 'already removed key leaves other content unchanged'

fixture partial
ssh_key_download() { printf 'ssh-ed25519 AAAAnew imported\nssh-ed25519 AAAAtwo second\n' > "$1"; }
ssh_key_configure --github test --user tester
printf 'ssh-ed25519 AAAAtwo second\n# preserved\n' > "$target"
ssh_key_rollback
assert_eq '# preserved' "$(cat "$target")" 'partially removed imports subtract only the remaining owned line'
ssh_key_download() { printf 'ssh-ed25519 AAAAnew imported\n' > "$1"; }

fixture symlink
ssh_key_configure --github test --user tester
mv "$target" "$root/outside"
ln -s "$root/outside" "$target"
cp "$root/outside" "$root/expected"
expect_failure 'rollback rejects a substituted symlink' ssh_key_rollback
same "$root/outside" "$root/expected" 'symlink target is untouched'

fixture identity
ssh_key_configure --github test --user tester
cp "$target" "$root/expected"
TEST_UID=99999
expect_failure 'rollback rejects changed account UID' ssh_key_rollback
unset TEST_UID
same "$target" "$root/expected" 'identity drift preserves authorizations'
mv "$VPS_SSH_KEY_HOME/.ssh" "$VPS_SSH_KEY_HOME/previous"
mkdir "$VPS_SSH_KEY_HOME/.ssh"
cp "$root/expected" "$target"
expect_failure 'rollback rejects replaced SSH directory identity' ssh_key_rollback

fixture home_link
mv "$VPS_SSH_KEY_HOME" "$root/real-home"
ln -s "$root/real-home" "$VPS_SSH_KEY_HOME"
expect_failure 'import rejects symlink home' ssh_key_configure --github test --user tester

fixture legacy
ssh_key_configure --github test --user tester
cp "$target" "$root/expected"
rm "$(vps_last_transaction "$MODULE_ID")/added"
expect_failure 'legacy transaction without ownership evidence refuses rollback' ssh_key_rollback
same "$target" "$root/expected" 'missing rollback evidence preserves keys'

fixture late_change
ssh_key_download() {
    mv "$VPS_SSH_KEY_HOME" "$root/moved-home"
    mkdir "$VPS_SSH_KEY_HOME"
    printf 'ssh-ed25519 AAAAnew imported\n' > "$1"
}
expect_failure 'import rechecks home identity after download' ssh_key_configure --github test --user tester
ssh_key_download() { printf 'ssh-ed25519 AAAAnew imported\n' > "$1"; }

eval "$(declare -f vps_set_last_transaction | sed '1s/vps_set_last_transaction/real_set_last_transaction/')"
vps_set_last_transaction() { return 1; }
fixture pointer_failure
expect_failure 'pointer failure aborts before authorizations change' ssh_key_configure --github test --user tester
if [[ ! -e "$target" ]]; then pass 'pointer failure creates no authorized_keys'; else fail 'pointer failure wrote keys'; fi
vps_set_last_transaction() { real_set_last_transaction "$@"; }

eval "$(declare -f ssh_tx_replace | sed '1s/ssh_tx_replace/real_tx_replace/')"
ssh_tx_replace() { return 1; }
fixture write_failure
expect_failure 'write failure is reported' ssh_key_configure --github test --user tester
assert_eq failed "$(cat "$(vps_last_transaction "$MODULE_ID")/phase")" 'write failure records failed state'
if [[ ! -e "$target" ]]; then pass 'failed write leaves target absent'; else fail 'failed write created target'; fi
ssh_tx_replace() { real_tx_replace "$@"; }

eval "$(declare -f ssh_tx_phase | sed '1s/ssh_tx_phase/real_tx_phase/')"
ssh_tx_phase() { [[ "$2" != committed ]] || return 1; real_tx_phase "$@"; }
fixture marker_failure
expect_failure 'commit marker failure is not reported as success' ssh_key_configure --github test --user tester
assert_eq compensated "$(cat "$(vps_last_transaction "$MODULE_ID")/phase")" 'marker failure records successful compensation'
if [[ ! -e "$target" ]]; then pass 'compensation restores absent target'; else fail 'compensation left imported keys'; fi

fixture marker_existing
mkdir "$VPS_SSH_KEY_HOME/.ssh"
printf '# retain original\n\nssh-ed25519 AAAAold old\n' > "$target"
cp "$target" "$root/expected"
expect_failure 'existing-file commit marker failure is surfaced' ssh_key_configure --github test --user tester
same "$target" "$root/expected" 'compensation restores original existing bytes'

ssh_tx_replace() { [[ "$1" != */original ]] || return 1; real_tx_replace "$@"; }
fixture compensation_failure
expect_failure 'compensation failure is surfaced' ssh_key_configure --github test --user tester
assert_contains "$(cat "$root/failure.log")" '自动恢复失败' 'recovery failure includes explicit diagnostic'
assert_file_exists "$target" 'failed compensation retains the evidence-bearing target'
assert_eq prepared "$(cat "$(vps_last_transaction "$MODULE_ID")/phase")" 'failed compensation remains incomplete'
ssh_tx_phase() { real_tx_phase "$@"; }
ssh_tx_replace() { real_tx_replace "$@"; }
expect_failure 'new import refuses to overwrite incomplete transaction' ssh_key_configure --github test --user tester
expect_failure 'incomplete transaction cannot silently roll back' ssh_key_rollback

fixture rollback_failure
ssh_key_configure --github test --user tester
ssh_tx_phase() { [[ "$2" != rolled_back ]] || return 1; real_tx_phase "$@"; }
expect_failure 'rollback completion marker failure is surfaced' ssh_key_rollback
assert_eq rollback_pending "$(cat "$(vps_last_transaction "$MODULE_ID")/phase")" 'interrupted rollback remains identifiable'
ssh_tx_phase() { real_tx_phase "$@"; }
printf 'ssh-ed25519 AAAAnew imported\n' > "$target"
cp "$target" "$root/expected"
expect_failure 'ambiguous interrupted rollback requires manual review' ssh_key_rollback
same "$target" "$root/expected" 'interrupted retry never removes a later reintroduced authorization'

fixture term_after_write
ssh_tx_replace() {
    real_tx_replace "$@" || return $?
    # This shell is a child of configure()s subshell, not of the test runner.
    sh -c 'kill -TERM "$PPID"'
    return 1
}
expect_failure 'TERM after atomic write does not report success' ssh_key_configure --github test --user tester
assert_eq prepared "$(cat "$(vps_last_transaction "$MODULE_ID")/phase")" 'TERM preserves identifiable incomplete transaction'
assert_file_exists "$target" 'TERM retains written keys for manual reconciliation'
assert_contains "$(cat "$root/failure.log")" '操作中断' 'TERM provides recovery guidance'

finish_tests
