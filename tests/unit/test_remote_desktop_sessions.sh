#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

temporary_root=$(mktemp -d)
proc_root="$temporary_root/proc"
cgroup_root="$temporary_root/cgroup"
session_log="$temporary_root/session.log"
session_done="$temporary_root/session.done"
apt_log="$temporary_root/apt.log"
mkdir -p "$proc_root" "$cgroup_root/session-42.scope"
: > "$session_log"
: > "$apt_log"

VPS_PLATFORM_ROOT=$PROJECT_ROOT
VPS_MODULE_ID=applications.remote-desktop
VPS_REMOTE_DESKTOP_CONFIG_DIR="$temporary_root/etc/remote-desktop"
VPS_REMOTE_DESKTOP_PROC_ROOT=$proc_root
VPS_REMOTE_DESKTOP_CGROUP_ROOT=$cgroup_root
VPS_REMOTE_DESKTOP_STOP_ATTEMPTS=1
VPS_REMOTE_DESKTOP_STOP_DELAY=0
export VPS_PLATFORM_ROOT VPS_MODULE_ID VPS_REMOTE_DESKTOP_CONFIG_DIR
export VPS_REMOTE_DESKTOP_PROC_ROOT VPS_REMOTE_DESKTOP_CGROUP_ROOT
export VPS_REMOTE_DESKTOP_STOP_ATTEMPTS VPS_REMOTE_DESKTOP_STOP_DELAY

# shellcheck source=../../modules/builtin/applications-remote-desktop/module.sh
source "$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"

id() {
    if [[ ${1:-} == -u && ${2:-} == desktop-user ]]; then
        printf '1000\n'
        return 0
    fi
    command id "$@"
}

make_process() {
    local pid=$1 uid=$2 comm=$3
    shift 3
    mkdir -p "$proc_root/$pid"
    printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\n' \
        "$comm" "$uid" "$uid" "$uid" "$uid" > "$proc_root/$pid/status"
    printf '%s\n' "$comm" > "$proc_root/$pid/comm"
    printf '%s\0' "$@" > "$proc_root/$pid/cmdline"
}

reset_managed_session() {
    rm -rf -- "$proc_root"
    mkdir -p "$proc_root" "$cgroup_root/session-42.scope"
    printf '%s\n' 100 101 102 > "$cgroup_root/session-42.scope/cgroup.procs"
    make_process 100 0 xrdp-sesman /usr/sbin/xrdp-sesman --nodaemon \
        --config "$VPS_REMOTE_DESKTOP_CONFIG_DIR/sesman.ini"
    make_process 101 1000 Xorg /usr/lib/xorg/Xorg :10 -config xrdp/xorg.conf
    make_process 102 1000 xfce4-session /usr/bin/xfce4-session
    rm -f -- "$session_done"
    : > "$session_log"
}

reset_closing_session() {
    rm -rf -- "$proc_root"
    mkdir -p "$proc_root" "$cgroup_root/session-42.scope"
    printf '%s\n' 110 111 > "$cgroup_root/session-42.scope/cgroup.procs"
    make_process 110 1000 xrdp-chansrv /usr/sbin/xrdp-chansrv
    make_process 111 1000 ssh-agent /usr/bin/ssh-agent -s
    rm -f -- "$session_done"
    : > "$session_log"
}

clear_managed_session() {
    local pid
    while IFS= read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        rm -rf -- "${proc_root:?}/$pid"
    done < "$cgroup_root/session-42.scope/cgroup.procs"
    : > "$cgroup_root/session-42.scope/cgroup.procs"
    : > "$session_done"
}

loginctl() {
    local operation=${1:-} session='' property='' argument
    shift || true
    case "$operation" in
        list-sessions)
            case ${VPS_TEST_SESSION_SCENARIO:-normal} in
                enumeration_failure) return 1 ;;
                non_xrdp) printf '77 1000 desktop-user\n' ;;
                *) [[ -e "$session_done" ]] || printf '42 1000 desktop-user\n' ;;
            esac
            ;;
        show-session)
            session=${1:-}
            shift || true
            for argument in "$@"; do
                case "$argument" in
                    --property=*) property=${argument#--property=} ;;
                esac
            done
            case "$session:$property" in
                77:User) printf '1000\n' ;;
                77:Service) printf 'sshd\n' ;;
                42:User) printf '1000\n' ;;
                42:Name) printf 'desktop-user\n' ;;
                42:Type) printf 'x11\n' ;;
                42:Service) printf 'xrdp-sesman\n' ;;
                42:Scope) printf 'session-42.scope\n' ;;
                42:State)
                    case ${VPS_TEST_SESSION_SCENARIO:-normal} in
                        closing_*) printf 'closing\n' ;;
                        *) printf 'active\n' ;;
                    esac
                    ;;
                *) return 1 ;;
            esac
            ;;
        terminate-session)
            session=${1:-}
            printf 'TERMINATE:%s\n' "$session" >> "$session_log"
            [[ "$session" == 42 ]] || return 64
            case ${VPS_TEST_SESSION_SCENARIO:-normal} in
                normal) clear_managed_session ;;
                closing_*) ;;
                *) return 64 ;;
            esac
            ;;
        *) return 64 ;;
    esac
}

systemctl() {
    local operation=${1:-} unit='' property='' signal='' kill_scope='' argument file
    shift || true
    case "$operation" in
        show)
            unit=${1:-}
            shift || true
            for argument in "$@"; do
                case "$argument" in
                    --property=*) property=${argument#--property=} ;;
                esac
            done
            [[ "$unit" == session-42.scope ]] || return 1
            file="$cgroup_root/session-42.scope/cgroup.procs"
            case "$property" in
                LoadState) printf 'loaded\n' ;;
                ControlGroup) printf '/session-42.scope\n' ;;
                MainPID)
                    if [[ -s "$file" ]]; then sed -n '1p' "$file"; else printf '0\n'; fi
                    ;;
                ControlPID) printf '0\n' ;;
                TasksCurrent) awk 'NF { count++ } END { print count + 0 }' "$file" ;;
                *) return 1 ;;
            esac
            ;;
        kill)
            for argument in "$@"; do
                case "$argument" in
                    --signal=*) signal=${argument#--signal=} ;;
                    --kill-whom=all) kill_scope=all ;;
                    --*) return 64 ;;
                    *) unit=$argument ;;
                esac
            done
            [[ "$unit" == session-42.scope && "$kill_scope" == all ]] || return 64
            printf 'SCOPE_SIGNAL:%s:%s\n' "$signal" "$unit" >> "$session_log"
            case ${VPS_TEST_SESSION_SCENARIO:-normal} in
                closing_term)
                    [[ "$signal" == TERM ]] && clear_managed_session
                    ;;
                closing_kill)
                    [[ "$signal" == KILL ]] && clear_managed_session
                    ;;
                closing_stuck) ;;
                *) return 64 ;;
            esac
            return 0
            ;;
        *) return 64 ;;
    esac
}

reset_managed_session
VPS_TEST_SESSION_SCENARIO=normal
export VPS_TEST_SESSION_SCENARIO
if rd_quiesce_xrdp_sessions desktop-user; then
    pass "rollback terminates the exact managed xrdp logind session"
else
    fail "rollback must terminate the exact managed xrdp logind session"
fi
actual=$(<"$session_log")
assert_eq 'TERMINATE:42' "$actual" \
    "rollback uses the exact logind session ID"
if [[ -s "$cgroup_root/session-42.scope/cgroup.procs" ]]; then
    fail "managed xrdp session cgroup must be empty after termination"
else
    pass "managed xrdp session cgroup is empty after termination"
fi

rm -rf -- "$proc_root"
mkdir -p "$proc_root"
make_process 200 1000 bash /bin/bash
: > "$session_log"
rm -f -- "$session_done"
VPS_TEST_SESSION_SCENARIO=non_xrdp
if rd_quiesce_xrdp_sessions desktop-user; then
    pass "rollback leaves a non-xrdp session untouched"
else
    fail "rollback must not reject or terminate an unrelated session"
fi
if [[ -s "$session_log" ]]; then
    fail "rollback must not terminate a non-xrdp session"
else
    pass "rollback does not issue termination for a non-xrdp session"
fi

reset_managed_session
printf '%s\n' "$$" >> "$cgroup_root/session-42.scope/cgroup.procs"
VPS_TEST_SESSION_SCENARIO=normal
if rd_quiesce_xrdp_sessions desktop-user >/dev/null 2>&1; then
    fail "rollback must reject a scope containing the current control process"
else
    actual=$?
    assert_eq 50 "$actual" \
        "current SSH/control process isolation fails closed"
fi
if [[ -s "$session_log" ]]; then
    fail "control-session validation must finish before session termination"
else
    pass "current control session is never terminated"
fi

reset_managed_session
sed -i.bak 's/Uid:\t1000/Uid:\t2000/' "$proc_root/102/status"
rm -f -- "$proc_root/102/status.bak"
VPS_TEST_SESSION_SCENARIO=normal
if rd_quiesce_xrdp_sessions desktop-user >/dev/null 2>&1; then
    fail "rollback must reject a session scope with an unexpected UID"
else
    actual=$?
    assert_eq 50 "$actual" \
        "uncertain session ownership fails closed"
fi
if [[ -s "$session_log" ]]; then
    fail "ownership validation must finish before session termination"
else
    pass "ownership failure does not terminate any session"
fi

reset_closing_session
VPS_TEST_SESSION_SCENARIO=closing_term
if rd_quiesce_xrdp_sessions desktop-user; then
    pass "rollback drains a closing xrdp session with user-only processes"
else
    fail "rollback must safely drain a verified closing xrdp session"
fi
actual=$(<"$session_log")
assert_contains "$actual" 'TERMINATE:42' \
    "closing-session cleanup first addresses the exact logind session"
assert_contains "$actual" 'SCOPE_SIGNAL:TERM:session-42.scope' \
    "closing-session cleanup sends TERM only to the exact session scope"
if [[ "$actual" == *'SCOPE_SIGNAL:KILL:'* ]]; then
    fail "closing-session cleanup must not send KILL after TERM succeeds"
else
    pass "closing-session cleanup avoids unnecessary KILL"
fi

reset_closing_session
sed -i.bak 's/Uid:\t1000/Uid:\t2000/' "$proc_root/111/status"
rm -f -- "$proc_root/111/status.bak"
VPS_TEST_SESSION_SCENARIO=closing_term
if rd_quiesce_xrdp_sessions desktop-user >/dev/null 2>&1; then
    fail "closing-session cleanup must reject an unexpected UID"
else
    actual=$?
    assert_eq 50 "$actual" \
        "closing-session unexpected UID fails closed"
fi
if [[ -s "$session_log" ]]; then
    fail "closing-session ownership validation must precede all signals"
else
    pass "closing-session unexpected UID receives no signal"
fi

reset_closing_session
sed -i.bak 's/Uid:\t1000/Uid:\t0/' "$proc_root/111/status"
rm -f -- "$proc_root/111/status.bak"
VPS_TEST_SESSION_SCENARIO=closing_term
if rd_quiesce_xrdp_sessions desktop-user >/dev/null 2>&1; then
    fail "closing-session cleanup must reject every root process"
else
    actual=$?
    assert_eq 50 "$actual" \
        "closing-session root process fails closed"
fi
if [[ -s "$session_log" ]]; then
    fail "closing-session root validation must precede all signals"
else
    pass "closing-session root process receives no signal"
fi

reset_closing_session
printf '%s\n' "$$" >> "$cgroup_root/session-42.scope/cgroup.procs"
VPS_TEST_SESSION_SCENARIO=closing_term
if rd_quiesce_xrdp_sessions desktop-user >/dev/null 2>&1; then
    fail "closing-session cleanup must reject the current control process"
else
    actual=$?
    assert_eq 50 "$actual" \
        "closing-session control process fails closed"
fi
if [[ -s "$session_log" ]]; then
    fail "closing-session control validation must precede all signals"
else
    pass "closing-session current control process receives no signal"
fi

reset_closing_session
VPS_TEST_SESSION_SCENARIO=closing_kill
if rd_quiesce_xrdp_sessions desktop-user; then
    pass "closing-session cleanup escalates to exact-scope KILL after TERM"
else
    fail "closing-session cleanup must use bounded exact-scope KILL escalation"
fi
actual=$(<"$session_log")
assert_contains "$actual" 'SCOPE_SIGNAL:TERM:session-42.scope' \
    "closing-session escalation tries exact-scope TERM first"
assert_contains "$actual" 'SCOPE_SIGNAL:KILL:session-42.scope' \
    "closing-session escalation keeps KILL on the exact scope"

reset_closing_session
VPS_TEST_SESSION_SCENARIO=closing_stuck
if rd_quiesce_xrdp_sessions desktop-user >/dev/null 2>&1; then
    fail "rollback must reject a session scope that remains populated"
else
    actual=$?
    assert_eq 50 "$actual" \
        "failed exact-session cleanup returns a bounded failure"
fi
actual=$(<"$session_log")
assert_contains "$actual" 'SCOPE_SIGNAL:TERM:session-42.scope' \
    "failed cleanup keeps TERM on the exact session scope"
assert_contains "$actual" 'SCOPE_SIGNAL:KILL:session-42.scope' \
    "failed cleanup keeps KILL on the exact session scope"

rollback_state="$temporary_root/rollback-state"
rollback_transaction="$rollback_state/modules/applications-remote-desktop/transactions/session-failure"
mkdir -p "$rollback_transaction"
cat > "$rollback_transaction/metadata" <<'EOF'
user=desktop-user
group=vpsrdp
group_existed=no
user_group=no
user_sudo=no
grant_sudo=no
EOF
printf 'xrdp\n' > "$rollback_transaction/packages.new"
VPS_STATE_DIR=$rollback_state
VPS_REMOTE_DESKTOP_TEST_MODE=yes
export VPS_STATE_DIR VPS_REMOTE_DESKTOP_TEST_MODE
rd_quiesce_xrdp_units() {
    return 0
}
apt-get() {
    printf '%s\n' "$*" >> "$apt_log"
}

rm -rf -- "$proc_root"
mkdir -p "$proc_root"
: > "$apt_log"
VPS_TEST_SESSION_SCENARIO=enumeration_failure
if rd_restore_transaction "$rollback_transaction" >/dev/null 2>&1; then
    fail "rollback must stop when logind session enumeration fails"
else
    actual=$?
    assert_eq 60 "$actual" \
        "logind enumeration failure stops the transaction"
fi
if [[ -s "$apt_log" ]]; then
    fail "enumeration failure must stop before package purge"
else
    pass "enumeration failure preserves installed packages"
fi
assert_file_exists "$rollback_transaction/packages.new" \
    "enumeration failure preserves package evidence"
if [[ -e "$rollback_transaction/rolled_back" ]]; then
    fail "enumeration failure must not mark the transaction rolled back"
else
    pass "enumeration failure leaves the transaction retryable"
fi

reset_closing_session
: > "$apt_log"
VPS_TEST_SESSION_SCENARIO=closing_stuck
if rd_restore_transaction "$rollback_transaction" >/dev/null 2>&1; then
    fail "rollback must stop when exact-session termination does not clear the scope"
else
    actual=$?
    assert_eq 60 "$actual" \
        "uncleared session scope stops the transaction"
fi
if [[ -s "$apt_log" ]]; then
    fail "failed session cleanup must stop before package purge"
else
    pass "failed session cleanup preserves installed packages"
fi
assert_file_exists "$rollback_transaction/packages.new" \
    "failed session cleanup preserves package evidence"
if [[ -e "$rollback_transaction/rolled_back" ]]; then
    fail "failed session cleanup must not mark the transaction rolled back"
else
    pass "failed session cleanup leaves the transaction retryable"
fi

rm -rf -- "$temporary_root"
finish_tests
