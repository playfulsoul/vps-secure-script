#!/usr/bin/env bash

set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)
VPS_PLATFORM_ROOT=$PROJECT_ROOT
VPS_MODULE_ID=applications.remote-desktop
export VPS_PLATFORM_ROOT VPS_MODULE_ID

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

temporary_root=$(mktemp -d)
mkdir -p "$temporary_root/bin" "$temporary_root/source"
cat > "$temporary_root/os-release" <<'EOF'
ID=debian
VERSION_ID="12"
EOF
cat > "$temporary_root/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$temporary_root/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
package=${!#}
case "$package" in
    absent-package) printf 'unknown ok not-installed' ;;
    partial-package) printf 'install ok unpacked' ;;
    installed-package) printf 'install ok installed' ;;
    *) exit 1 ;;
esac
EOF
cat > "$temporary_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -u
operation=${1:-}
unit=${2:-}
case "$operation" in
    list-unit-files)
        case ${VPS_TEST_PANEL_LAYOUT:-absent} in
            absent) ;;
            failure) exit 1 ;;
            single) printf '1panel.service enabled\n' ;;
            split)
                printf '%s\n' \
                    '1panel-beta.service enabled' \
                    '1panel-alpha.service enabled' \
                    '1panel-alpha.service enabled'
                ;;
            partial) printf '1panel-alpha.service enabled\n' ;;
        esac
        ;;
    is-active)
        case "$unit" in
            1panel|1panel-alpha) printf 'active\n' ;;
            1panel-beta) printf '%s\n' "${VPS_TEST_PANEL_BETA_STATE:-inactive}" ;;
            fail2ban) printf 'active\n' ;;
            *) printf 'inactive\n' ;;
        esac
        ;;
    get-default)
        printf 'graphical.target\n'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$temporary_root/bin/apt-get" "$temporary_root/bin/dpkg-query" \
    "$temporary_root/bin/systemctl"

cat > "$temporary_root/source/xrdp.ini" <<'EOF'
[Globals]
port=3389
security_layer=negotiate

[Channels]
rdpdr=true
rdpsnd=true
cliprdr=true
rail=true
xrdpvr=true

[Xorg]
name=Xorg
lib=libxup.so
ip=127.0.0.1
port=-1
EOF
cat > "$temporary_root/source/sesman.ini" <<'EOF'
[Globals]
ListenAddress=127.0.0.1
ListenPort=3350
EnableUserWindowManager=true
DefaultWindowManager=startwm.sh

[Security]
AllowRootLogin=true
MaxLoginRetry=4
TerminalServerUsers=tsusers
AlwaysGroupCheck=false

[Sessions]
MaxSessions=50
KillDisconnected=false
DisconnectedTimeLimit=0
IdleTimeLimit=0
EOF

export VPS_OS_RELEASE_FILE="$temporary_root/os-release"
export VPS_REMOTE_DESKTOP_CONFIG_DIR="$temporary_root/etc/remote-desktop"
export VPS_REMOTE_DESKTOP_LIB_DIR="$temporary_root/lib/remote-desktop"
export VPS_REMOTE_DESKTOP_XRDP_DROPIN="$temporary_root/systemd/xrdp/90-vps-secure.conf"
export VPS_REMOTE_DESKTOP_SESMAN_DROPIN="$temporary_root/systemd/sesman/90-vps-secure.conf"
export VPS_REMOTE_DESKTOP_XRDP_SOURCE="$temporary_root/source/xrdp.ini"
export VPS_REMOTE_DESKTOP_SESMAN_SOURCE="$temporary_root/source/sesman.ini"
export VPS_REMOTE_DESKTOP_SKIP_COMMAND_CHECK=yes
export PATH="$temporary_root/bin:$PATH"

# shellcheck source=../../modules/builtin/applications-remote-desktop/module.sh
source "$PROJECT_ROOT/modules/builtin/applications-remote-desktop/module.sh"

if rd_package_present absent-package; then
    fail "dpkg unknown/not-installed records must be treated as absent"
else
    pass "dpkg unknown/not-installed records are treated as absent"
fi
if rd_package_present partial-package; then
    pass "partial dpkg records remain visible to the safety check"
else
    fail "partial dpkg records must remain visible to the safety check"
fi
if rd_package_installed installed-package; then
    pass "fully installed dpkg records are recognized"
else
    fail "fully installed dpkg records must be recognized"
fi

VPS_TEST_PANEL_LAYOUT='absent'
export VPS_TEST_PANEL_LAYOUT
actual=$(rd_panel_service_states)
assert_eq absent "$actual" "remote desktop records an absent 1Panel installation"
VPS_TEST_PANEL_LAYOUT='single'
actual=$(rd_panel_service_states)
assert_eq '1panel:active' "$actual" "remote desktop records a single 1Panel service"
VPS_TEST_PANEL_LAYOUT='split'
actual=$(rd_panel_service_states)
assert_eq '1panel-alpha:active,1panel-beta:inactive' "$actual" \
    "remote desktop records split 1Panel services and their exact states"
VPS_TEST_PANEL_LAYOUT='partial'
actual=$(rd_panel_service_states)
assert_eq '1panel-alpha:active' "$actual" \
    "remote desktop records the deployed subset of 1Panel services"
VPS_TEST_PANEL_LAYOUT='failure'
if rd_panel_service_states >/dev/null 2>&1; then
    fail "remote desktop must not treat a failed 1Panel enumeration as absent"
else
    pass "remote desktop fails closed when 1Panel enumeration fails"
fi

VPS_REMOTE_DESKTOP_MEMORY_MB=1024
VPS_REMOTE_DESKTOP_CPU_COUNT=1
VPS_REMOTE_DESKTOP_FREE_DISK_MB=7000
export VPS_REMOTE_DESKTOP_MEMORY_MB VPS_REMOTE_DESKTOP_CPU_COUNT VPS_REMOTE_DESKTOP_FREE_DISK_MB
actual=$(rd_recommend_profile)
assert_eq lxqt "$actual" "low-resource systems recommend LXQt"

VPS_REMOTE_DESKTOP_MEMORY_MB=2048
VPS_REMOTE_DESKTOP_CPU_COUNT=2
VPS_REMOTE_DESKTOP_FREE_DISK_MB=20000
actual=$(rd_recommend_profile)
assert_eq xfce "$actual" "2 GB systems recommend XFCE"

VPS_REMOTE_DESKTOP_MEMORY_MB=4096
VPS_REMOTE_DESKTOP_FREE_DISK_MB=20000
actual=$(rd_recommend_profile)
assert_eq mate "$actual" "4 GB systems can recommend MATE"

rd_parse_options --profile lxqt --user desktop --create-user --browser auto --set-password
rd_normalize_options
assert_eq none "$RD_BROWSER" "LXQt auto profile does not force a browser"

rd_parse_options --profile xfce --user desktop --create-user --browser auto --set-password
rd_normalize_options
assert_eq firefox "$RD_BROWSER" "XFCE auto profile recommends Firefox"

actual=$(rd_unique_packages)
assert_contains "$actual" xrdp "remote desktop package set contains xrdp"
assert_contains "$actual" xorgxrdp "remote desktop package set contains xorgxrdp"
assert_contains "$actual" xfce4 "XFCE package set contains xfce4"
assert_contains "$actual" fonts-noto-cjk \
    "XFCE package set contains Chinese display fonts"
assert_contains "$actual" firefox-esr "Debian browser selection uses Firefox ESR"
if [[ "$actual" == *gnome* || "$actual" == *lightdm* ]]; then
    fail "remote desktop package set must not install GNOME or a display manager"
else
    pass "remote desktop package set omits GNOME and display managers"
fi

for profile in lxqt xfce mate; do
    rd_parse_options --profile "$profile" --user desktop --browser none
    actual=$(rd_unique_packages)
    assert_contains "$actual" fonts-noto-cjk \
        "$profile package set contains Chinese display fonts"
    actual=$(printf '%s\n' "$actual" | grep -Fxc fonts-noto-cjk)
    assert_eq 1 "$actual" "$profile package set contains the font package once"
done

rd_parse_options --profile xfce --user desktop --browser firefox

rd_prepare_owned_config
rd_write_systemd_dropins
assert_file_exists "$VPS_REMOTE_DESKTOP_CONFIG_DIR/xrdp.ini" \
    "remote desktop renders a platform-owned xrdp config"
assert_file_exists "$VPS_REMOTE_DESKTOP_CONFIG_DIR/sesman.ini" \
    "remote desktop renders a platform-owned sesman config"
assert_file_exists "$VPS_REMOTE_DESKTOP_CONFIG_DIR/xrdp.env" \
    "remote desktop renders a late-loading xrdp option file"
assert_file_exists "$VPS_REMOTE_DESKTOP_CONFIG_DIR/sesman.env" \
    "remote desktop renders a late-loading sesman option file"
actual=$(<"$VPS_REMOTE_DESKTOP_CONFIG_DIR/xrdp.ini")
assert_contains "$actual" 'port=tcp://127.0.0.1:3389' \
    "xrdp is pinned to IPv4 loopback"
assert_contains "$actual" 'rdpdr=false' "drive and printer redirection are disabled"
assert_contains "$actual" 'rdpsnd=false' "audio redirection is disabled"
assert_contains "$actual" 'cliprdr=true' "the text clipboard channel remains available"
actual=$(<"$VPS_REMOTE_DESKTOP_CONFIG_DIR/sesman.ini")
assert_contains "$actual" 'AllowRootLogin=false' "root graphical login is disabled"
assert_contains "$actual" 'TerminalServerUsers=vpsrdp' \
    "only the dedicated remote desktop group can log in"
assert_contains "$actual" 'AlwaysGroupCheck=true' "the login group is always enforced"
assert_contains "$actual" 'EnableUserWindowManager=false' \
    "user session overrides cannot bypass the selected desktop"
assert_contains "$actual" 'RestrictInboundClipboard=file,image' \
    "inbound clipboard is text-only"
assert_contains "$actual" 'RestrictOutboundClipboard=file,image' \
    "outbound clipboard is text-only"
actual=$(<"$VPS_REMOTE_DESKTOP_LIB_DIR/startwm.sh")
assert_contains "$actual" 'startxfce4' "the managed session starts the selected desktop"
actual=$(<"$VPS_REMOTE_DESKTOP_CONFIG_DIR/xrdp.env")
assert_contains "$actual" "XRDP_OPTIONS=\"--config $VPS_REMOTE_DESKTOP_CONFIG_DIR/xrdp.ini\"" \
    "xrdp options point to the platform-owned configuration"
actual=$(<"$VPS_REMOTE_DESKTOP_CONFIG_DIR/sesman.env")
assert_contains "$actual" "SESMAN_OPTIONS=\"--config $VPS_REMOTE_DESKTOP_CONFIG_DIR/sesman.ini\"" \
    "sesman options point to the platform-owned configuration"
actual=$(<"$VPS_REMOTE_DESKTOP_XRDP_DROPIN")
assert_contains "$actual" "EnvironmentFile=$VPS_REMOTE_DESKTOP_CONFIG_DIR/xrdp.env" \
    "xrdp loads platform options after vendor environment files"
actual=$(<"$VPS_REMOTE_DESKTOP_SESMAN_DROPIN")
assert_contains "$actual" "EnvironmentFile=$VPS_REMOTE_DESKTOP_CONFIG_DIR/sesman.env" \
    "sesman loads platform options after vendor environment files"

if rd_user_valid root; then
    fail "root cannot be selected as the desktop user"
else
    pass "root cannot be selected as the desktop user"
fi
if rd_user_valid desktop-user; then
    pass "ordinary desktop usernames are accepted"
else
    fail "ordinary desktop usernames are accepted"
fi

VPS_REMOTE_DESKTOP_LISTENER_STATE=public
export VPS_REMOTE_DESKTOP_LISTENER_STATE
actual=$(rd_rdp_listener_state)
assert_eq public "$actual" "listener verification distinguishes public RDP"
VPS_REMOTE_DESKTOP_LISTENER_STATE=loopback
actual=$(rd_rdp_listener_state)
assert_eq loopback "$actual" "listener verification recognizes loopback-only RDP"
VPS_REMOTE_DESKTOP_LISTENER_ATTEMPTS=1
VPS_REMOTE_DESKTOP_LISTENER_DELAY=0
export VPS_REMOTE_DESKTOP_LISTENER_ATTEMPTS VPS_REMOTE_DESKTOP_LISTENER_DELAY
if rd_wait_for_loopback_listener; then
    pass "listener readiness accepts a loopback-only listener"
else
    fail "listener readiness must accept a loopback-only listener"
fi
VPS_REMOTE_DESKTOP_LISTENER_STATE=public
if rd_wait_for_loopback_listener >/dev/null 2>&1; then
    fail "listener readiness must reject a public listener"
else
    pass "listener readiness rejects a public listener immediately"
fi
VPS_REMOTE_DESKTOP_LISTENER_STATE=none
if rd_wait_for_loopback_listener >/dev/null 2>&1; then
    fail "listener readiness must fail closed when no listener appears"
else
    pass "listener readiness fails closed when no listener appears"
fi

transaction="$temporary_root/transaction"
mkdir -p "$transaction"
printf '%s\n' base-package existing-library > "$transaction/packages.present.before"
rd_present_packages() {
    printf '%s\n' base-package desktop-dependency existing-library xrdp
}
rd_record_new_packages "$transaction"
actual=$(<"$transaction/packages.new")
assert_eq $'desktop-dependency\nxrdp' "$actual" \
    "transaction inventory records every newly introduced package"

legacy_transaction="$temporary_root/legacy-transaction"
mkdir -p "$legacy_transaction"
cat > "$legacy_transaction/metadata" <<'EOF'
default_target=graphical.target
ssh_ports=2222
ufw_hash=unchanged
fail2ban_active=active
panel_active=active
EOF
vps_require_ssh_ports() {
    printf '2222\n'
}
rd_ufw_hash() {
    printf 'unchanged\n'
}
VPS_TEST_PANEL_LAYOUT='single'
if rd_verify_baseline "$legacy_transaction"; then
    pass "legacy panel_active metadata remains valid for rollback verification"
else
    fail "legacy panel_active metadata must remain valid for rollback verification"
fi

split_transaction="$temporary_root/split-transaction"
mkdir -p "$split_transaction"
cat > "$split_transaction/metadata" <<'EOF'
default_target=graphical.target
ssh_ports=2222
ufw_hash=unchanged
fail2ban_active=active
panel_active=not-found
panel_services=1panel-alpha:active,1panel-beta:inactive
EOF
VPS_TEST_PANEL_LAYOUT='split'
VPS_TEST_PANEL_BETA_STATE='inactive'
export VPS_TEST_PANEL_BETA_STATE
if rd_verify_baseline "$split_transaction"; then
    pass "split 1Panel service states remain valid when unchanged"
else
    fail "unchanged split 1Panel service states must pass baseline verification"
fi
VPS_TEST_PANEL_BETA_STATE='active'
if rd_verify_baseline "$split_transaction" >/dev/null 2>&1; then
    fail "changed split 1Panel service states must fail baseline verification"
else
    pass "changed split 1Panel service states fail baseline verification"
fi

enumeration_transaction="$temporary_root/enumeration-transaction"
mkdir -p "$enumeration_transaction"
cat > "$enumeration_transaction/metadata" <<'EOF'
default_target=graphical.target
ssh_ports=2222
ufw_hash=unchanged
fail2ban_active=active
panel_active=not-found
panel_services=absent
EOF
VPS_TEST_PANEL_LAYOUT='failure'
if rd_verify_baseline "$enumeration_transaction" >/dev/null 2>&1; then
    fail "baseline verification must reject a failed 1Panel enumeration"
else
    actual=$?
    assert_eq 50 "$actual" \
        "failed 1Panel enumeration returns a verification failure"
fi

failed_transaction="$temporary_root/failed-create-transaction"
vps_new_transaction_dir() {
    mkdir -p "$failed_transaction"
    printf '%s\n' "$failed_transaction"
}
if rd_create_transaction >/dev/null 2>&1; then
    fail "transaction creation must reject a failed 1Panel enumeration"
else
    actual=$?
    assert_eq 40 "$actual" \
        "failed 1Panel enumeration aborts transaction creation"
fi
if [[ -e "$failed_transaction/metadata" ]]; then
    fail "failed 1Panel enumeration must not create transaction metadata"
else
    pass "failed 1Panel enumeration leaves no successful transaction metadata"
fi

quiesce_root="$temporary_root/cgroup"
quiesce_log="$temporary_root/quiesce.log"
mkdir -p "$quiesce_root/system.slice/xrdp.service" \
    "$quiesce_root/system.slice/xrdp-sesman.service"
export VPS_REMOTE_DESKTOP_CGROUP_ROOT="$quiesce_root"
export VPS_REMOTE_DESKTOP_STOP_ATTEMPTS=1
export VPS_REMOTE_DESKTOP_STOP_DELAY=0
export VPS_TEST_QUIESCE_LOG="$quiesce_log"

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
            file="$VPS_REMOTE_DESKTOP_CGROUP_ROOT/system.slice/$unit/cgroup.procs"
            case "$property" in
                LoadState) printf 'loaded\n' ;;
                ControlGroup) printf '/system.slice/%s\n' "$unit" ;;
                MainPID)
                    if [[ -s "$file" ]]; then
                        sed -n '1p' "$file"
                    else
                        printf '0\n'
                    fi
                    ;;
                ControlPID) printf '0\n' ;;
                TasksCurrent) wc -l < "$file" | tr -d ' ' ;;
                *) return 1 ;;
            esac
            ;;
        stop)
            printf 'STOP:%s\n' "$*" >> "$VPS_TEST_QUIESCE_LOG"
            if [[ ${VPS_TEST_QUIESCE_SCENARIO:-} == stop_success ]]; then
                : > "$VPS_REMOTE_DESKTOP_CGROUP_ROOT/system.slice/xrdp.service/cgroup.procs"
                : > "$VPS_REMOTE_DESKTOP_CGROUP_ROOT/system.slice/xrdp-sesman.service/cgroup.procs"
            fi
            ;;
        mask)
            printf 'MASK:%s\n' "$*" >> "$VPS_TEST_QUIESCE_LOG"
            ;;
        kill)
            for argument in "$@"; do
                case "$argument" in
                    --signal=*) signal=${argument#--signal=} ;;
                    --kill-whom=all) kill_scope=all ;;
                    --kill-who=*) return 64 ;;
                    --*) ;;
                    *) unit=$argument ;;
                esac
            done
            [[ "$kill_scope" == all ]] || return 64
            printf '%s:%s\n' "$signal" "$unit" >> "$VPS_TEST_QUIESCE_LOG"
            file="$VPS_REMOTE_DESKTOP_CGROUP_ROOT/system.slice/$unit/cgroup.procs"
            case ${VPS_TEST_QUIESCE_SCENARIO:-} in
                term_success)
                    [[ "$signal" == TERM ]] && : > "$file"
                    ;;
                kill_required)
                    [[ "$signal" == KILL ]] && : > "$file"
                    ;;
                stuck) ;;
            esac
            return 0
            ;;
        *) "$temporary_root/bin/systemctl" "$operation" "$@" ;;
    esac
}

printf '101\n' > "$quiesce_root/system.slice/xrdp.service/cgroup.procs"
printf '102\n' > "$quiesce_root/system.slice/xrdp-sesman.service/cgroup.procs"
: > "$quiesce_log"
VPS_TEST_QUIESCE_SCENARIO=term_success
export VPS_TEST_QUIESCE_SCENARIO
if rd_quiesce_xrdp_units; then
    pass "rollback drains lingering unit cgroups with TERM"
else
    fail "rollback must drain lingering unit cgroups with TERM"
fi
actual=$(<"$quiesce_log")
assert_contains "$actual" 'TERM:xrdp.service' \
    "rollback targets the xrdp unit cgroup instead of a process name"
assert_contains "$actual" 'TERM:xrdp-sesman.service' \
    "rollback targets the sesman unit cgroup instead of a process name"
if [[ "$actual" == *'KILL:'* ]]; then
    fail "rollback must not send KILL after TERM clears the unit cgroups"
else
    pass "rollback avoids KILL when TERM clears the unit cgroups"
fi

printf '201\n' > "$quiesce_root/system.slice/xrdp.service/cgroup.procs"
printf '202\n' > "$quiesce_root/system.slice/xrdp-sesman.service/cgroup.procs"
: > "$quiesce_log"
VPS_TEST_QUIESCE_SCENARIO=kill_required
if rd_quiesce_xrdp_units; then
    pass "rollback escalates to KILL when TERM leaves unit cgroup processes"
else
    fail "rollback must use bounded KILL escalation for a lingering unit cgroup"
fi
actual=$(<"$quiesce_log")
assert_contains "$actual" 'KILL:xrdp.service' \
    "rollback KILL escalation remains scoped to the xrdp unit"
assert_contains "$actual" 'KILL:xrdp-sesman.service' \
    "rollback KILL escalation remains scoped to the sesman unit"

printf '301\n' > "$quiesce_root/system.slice/xrdp.service/cgroup.procs"
printf '302\n' > "$quiesce_root/system.slice/xrdp-sesman.service/cgroup.procs"
: > "$quiesce_log"
VPS_TEST_QUIESCE_SCENARIO=stuck
if rd_quiesce_xrdp_units >/dev/null 2>&1; then
    fail "rollback must fail closed when a unit cgroup cannot be emptied"
else
    actual=$?
    assert_eq 50 "$actual" \
        "an uncleared unit cgroup returns a bounded stop failure"
fi

rollback_state="$temporary_root/rollback-state"
rollback_transaction="$rollback_state/modules/applications-remote-desktop/transactions/stuck"
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
: > "$temporary_root/apt.log"
VPS_STATE_DIR="$rollback_state"
VPS_REMOTE_DESKTOP_TEST_MODE=yes
export VPS_STATE_DIR VPS_REMOTE_DESKTOP_TEST_MODE
apt-get() {
    printf '%s\n' "$*" >> "$temporary_root/apt.log"
}
if rd_restore_transaction "$rollback_transaction" >/dev/null 2>&1; then
    fail "rollback must not continue when managed unit processes survive"
else
    actual=$?
    assert_eq 60 "$actual" \
        "an uncleared managed unit stops the transaction before package purge"
fi
if [[ -s "$temporary_root/apt.log" ]]; then
    fail "rollback must preserve packages when unit cgroup exit cannot be confirmed"
else
    pass "rollback preserves packages when unit cgroup exit cannot be confirmed"
fi
assert_file_exists "$rollback_transaction/packages.new" \
    "failed rollback preserves the exact package inventory evidence"
if [[ -e "$rollback_transaction/rolled_back" ]]; then
    fail "failed rollback must not mark the transaction as rolled back"
else
    pass "failed rollback leaves the transaction available for diagnosis and retry"
fi

rm -rf -- "$temporary_root"
finish_tests
