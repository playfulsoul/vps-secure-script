#!/usr/bin/env bash

# Test doubles are invoked indirectly by the loaded module functions.
# shellcheck disable=SC2317,SC2329
set -u

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$TEST_DIR/../.." && pwd)

# shellcheck source=../test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# shellcheck source=../../core/modules.sh
source "$PROJECT_ROOT/core/modules.sh"

test_root=$(mktemp -d)
test_root=$(cd "$test_root" && pwd -P)
trap 'rm -rf -- "$test_root"' EXIT

export VPS_PLATFORM_ROOT=$PROJECT_ROOT
export VPS_MODULE_ID=applications.beszel-hub
export VPS_BESZEL_HUB_SERVICE=beszel-test.service
export VPS_BESZEL_HUB_DATA_DIR="$test_root/live/beszel_data"
export VPS_BESZEL_HUB_BACKUP_DIR="$test_root/backups"
export VPS_BESZEL_HUB_STATE_DIR="$test_root/state/beszel-hub"
export VPS_BESZEL_HUB_HEALTH_URL=http://127.0.0.1:18090/api/health
export VPS_BESZEL_HUB_RCLONE_CONFIG="$test_root/rclone.conf"
export VPS_BESZEL_HUB_RCLONE_CONFIG_OWNER_UID
VPS_BESZEL_HUB_RCLONE_CONFIG_OWNER_UID=$(id -u)
export VPS_BESZEL_HUB_ONEDRIVE_CONFIG="$test_root/etc/beszel-hub-onedrive.conf"
export VPS_BESZEL_HUB_ONEDRIVE_SERVICE="$test_root/systemd/vps-secure-beszel-hub-onedrive.service"
export VPS_BESZEL_HUB_ONEDRIVE_TIMER="$test_root/systemd/vps-secure-beszel-hub-onedrive.timer"
export VPS_BESZEL_HUB_VPS_COMMAND="$PROJECT_ROOT/bin/vps"

# shellcheck source=../../modules/builtin/applications-beszel-hub/module.sh
source "$PROJECT_ROOT/modules/builtin/applications-beszel-hub/module.sh"

vps_require_root() { return 0; }
hub_check() { hub_data_dir_valid; }

service_state="$test_root/service-state"
timer_state="$test_root/timer-state"
timer_enabled="$test_root/timer-enabled"
systemctl_log="$test_root/systemctl.log"
printf 'active\n' > "$service_state"
printf 'inactive\n' > "$timer_state"
printf 'disabled\n' > "$timer_enabled"
: > "$systemctl_log"

systemctl() {
    local unit=${!#}
    printf '%s\n' "$*" >> "$systemctl_log"
    case $1 in
        show)
            if [[ "$unit" == NextElapseUSecRealtime || "$*" == *NextElapseUSecRealtime* ]]; then
                printf 'Sun 2026-09-27 04:30:00 CST\n'
            elif [[ "$*" == *'-p Environment'* ]]; then
                printf 'APP_URL=%s\n' "${VPS_TEST_APP_URL:-}"
            elif [[ "$*" == *' Result '* || "$*" == *'-p Result'* ]]; then
                printf 'success\n'
            fi
            return 0
            ;;
        is-active)
            if [[ "$unit" == vps-secure-beszel-hub-onedrive.timer ]]; then
                if grep -q '^active$' "$timer_state"; then
                    [[ "$*" == *'--quiet'* ]] || printf 'active\n'
                else
                    [[ "$*" == *'--quiet'* ]] || printf 'inactive\n'
                    return 3
                fi
            else
                grep -q '^active$' "$service_state"
            fi
            ;;
        is-enabled)
            if grep -q '^enabled$' "$timer_enabled"; then
                [[ "$*" == *'--quiet'* ]] || printf 'enabled\n'
            else
                [[ "$*" == *'--quiet'* ]] || printf 'disabled\n'
                return 1
            fi
            ;;
        enable)
            [[ ${VPS_TEST_TIMER_ENABLE_FAIL:-no} != yes ]] || return 1
            printf 'enabled\n' > "$timer_enabled"
            [[ "$*" != *'--now'* ]] || printf 'active\n' > "$timer_state"
            ;;
        disable)
            printf 'disabled\n' > "$timer_enabled"
            [[ "$*" != *'--now'* ]] || printf 'inactive\n' > "$timer_state"
            ;;
        stop)
            if [[ "$unit" == vps-secure-beszel-hub-onedrive.timer ]]; then
                printf 'inactive\n' > "$timer_state"
            else
                printf 'inactive\n' > "$service_state"
            fi
            ;;
        start)
            if [[ ${VPS_TEST_START_FAIL:-no} == yes ]]; then return 1; fi
            if [[ "$unit" == vps-secure-beszel-hub-onedrive.timer ]]; then
                printf 'active\n' > "$timer_state"
            else
                printf 'active\n' > "$service_state"
            fi
            ;;
        *) return 0 ;;
    esac
}

curl() {
    local value=''
    health_attempts=$((health_attempts + 1))
    if (( health_attempts <= ${VPS_TEST_HEALTH_DELAY_ATTEMPTS:-0} )); then
        return 22
    fi
    [[ -r "$BESZEL_HUB_DATA_DIR/value" ]] && value=$(<"$BESZEL_HUB_DATA_DIR/value")
    if [[ ${VPS_TEST_HEALTH_FAIL_ON_NEW:-no} == yes && "$value" == new* ]]; then
        return 22
    fi
    [[ ${VPS_TEST_HEALTH_ALWAYS_FAIL:-no} != yes ]]
}

remote_store="$test_root/remote-store"
rclone() {
    local config='' command source destination name
    if [[ ${1:-} == --config ]]; then
        config=$2
        shift 2
    fi
    [[ "$config" == "$VPS_BESZEL_HUB_RCLONE_CONFIG" ]] || return 1
    command=${1:-}
    shift || true
    case "$command" in
        lsf)
            [[ -d "$remote_store" ]] || return 0
            find "$remote_store" -maxdepth 1 -type f -print | while IFS= read -r source; do
                basename -- "$source"
            done
            ;;
        config)
            [[ ${1:-} == redacted ]] || return 1
            case ${2:-} in
                vps-onedrive-crypt)
                    printf '%s\n' '[vps-onedrive-crypt]' 'type = crypt' \
                        'remote = vps-onedrive-raw:vps-secure/beszel-hub' \
                        'password = XXX' 'password2 = XXX'
                    ;;
                vps-onedrive-raw)
                    if [[ ${VPS_TEST_BACKING_TYPE:-onedrive} == onedrive ]]; then
                        printf '%s\n' '[vps-onedrive-raw]' 'type = onedrive' 'token = XXX'
                    else
                        printf '%s\n' '[vps-onedrive-raw]' 'type = s3' 'secret_access_key = XXX'
                    fi
                    ;;
                unencrypted)
                    printf '%s\n' '[unencrypted]' 'type = onedrive' 'token = XXX'
                    ;;
                *) return 1 ;;
            esac
            ;;
        copyto)
            source=${1:-}
            destination=${2:-}
            [[ ${VPS_TEST_RCLONE_FAIL:-no} != yes ]] || return 1
            mkdir -p "$remote_store"
            if [[ "$source" == *:* ]]; then
                name=${source##*/}
                cp -- "$remote_store/$name" "$destination" || return 1
                if [[ ${VPS_TEST_RCLONE_TAMPER:-no} == yes && "$destination" != *.sha256 ]]; then
                    printf 'tampered\n' >> "$destination"
                fi
            else
                name=${destination##*/}
                cp -- "$source" "$remote_store/$name"
            fi
            ;;
        *) return 1 ;;
    esac
}

reset_target() {
    rm -rf -- "${test_root:?}/live" "${BESZEL_HUB_STATE_DIR:?}" \
        "${test_root:?}/etc" "${test_root:?}/systemd"
    mkdir -p "$BESZEL_HUB_DATA_DIR" "$BESZEL_HUB_STATE_DIR" "$test_root/etc" "$test_root/systemd"
    printf 'old\n' > "$BESZEL_HUB_DATA_DIR/value"
    printf 'active\n' > "$service_state"
    printf 'inactive\n' > "$timer_state"
    printf 'disabled\n' > "$timer_enabled"
    : > "$systemctl_log"
    health_attempts=0
    unset VPS_TEST_HEALTH_FAIL_ON_NEW VPS_TEST_HEALTH_ALWAYS_FAIL VPS_TEST_START_FAIL \
        VPS_TEST_HEALTH_DELAY_ATTEMPTS VPS_TEST_RCLONE_FAIL VPS_TEST_RCLONE_TAMPER \
        VPS_TEST_BACKING_TYPE VPS_TEST_TIMER_ENABLE_FAIL VPS_TEST_APP_URL
}

create_bundle() {
    local name=$1 value=$2 root archive
    root="$test_root/bundle-$name"
    archive="$test_root/$name.tar.gz"
    rm -rf -- "$root" "$archive" "$archive.sha256"
    mkdir -p "$root/beszel_data/nested"
    printf '%s\n' "format=$BESZEL_HUB_FORMAT" 'created_utc=2026-09-26T00:00:00Z' > "$root/manifest"
    printf '%s\n' "$value" > "$root/beszel_data/value"
    printf 'history\n' > "$root/beszel_data/nested/history.db"
    tar -czf "$archive" -C "$root" manifest beszel_data
    sha256sum "$archive" | awk -v name="$(basename -- "$archive")" \
        '{print $1 "  " name}' > "$archive.sha256"
    printf '%s\n' "$archive"
}

manifest="$PROJECT_ROOT/modules/builtin/applications-beszel-hub/module.conf"
if vps_validate_manifest "$manifest"; then
    pass 'Beszel Hub manifest satisfies the module contract'
else
    fail 'Beszel Hub manifest must satisfy the module contract'
fi

reset_target
actual=$(hub_status)
assert_contains "$actual" '邮件链接可能指向 localhost' \
    'Hub status warns when the public notification URL is unset'
export VPS_TEST_APP_URL=http://localhost:8090
actual=$(hub_status)
assert_contains "$actual" '未设置有效 HTTPS 地址' \
    'Hub status does not accept a loopback HTTP notification URL'
export VPS_TEST_APP_URL=https://monitor.example.com
actual=$(hub_status)
assert_contains "$actual" '告警链接地址: https://monitor.example.com' \
    'Hub status shows the configured public notification URL'
unset VPS_TEST_APP_URL

first_transaction=$(hub_new_transaction_dir)
second_transaction=$(hub_new_transaction_dir)
if [[ "$first_transaction" != "$second_transaction" && \
      -d "$first_transaction" && -d "$second_transaction" ]]; then
    pass 'rapid Hub operations receive separate transaction directories'
else
    fail 'rapid Hub operations must not reuse transaction directories'
fi

reset_target
mkdir -p "$VPS_BESZEL_HUB_BACKUP_DIR"
printf 'database\n' > "$BESZEL_HUB_DATA_DIR/data.db"
backup="$VPS_BESZEL_HUB_BACKUP_DIR/manual.tar.gz"
actual=$(hub_backup --output "$backup")
assert_contains "$actual" '离线备份已创建' 'backup reports the completed offline archive'
assert_file_exists "$backup" 'backup creates the archive'
assert_file_exists "$backup.sha256" 'backup creates a detached checksum'
if (cd "$(dirname -- "$backup")" && sha256sum -c "$(basename -- "$backup.sha256")") >/dev/null 2>&1; then
    pass 'backup checksum verifies'
else
    fail 'backup checksum must verify'
fi
archive_list=$(tar -tzf "$backup")
assert_contains "$archive_list" 'manifest' 'backup contains the format manifest'
assert_contains "$archive_list" 'beszel_data/data.db' 'backup contains Hub data'
assert_eq active "$(cat "$service_state")" 'backup restores an originally active service'
commands=$(cat "$systemctl_log")
assert_contains "$commands" 'stop beszel-test.service' 'backup stops the Hub before copying data'
assert_contains "$commands" 'start beszel-test.service' 'backup restarts the Hub after copying data'

reset_target
export VPS_TEST_HEALTH_DELAY_ATTEMPTS=2
delayed_backup="$VPS_BESZEL_HUB_BACKUP_DIR/delayed-start.tar.gz"
actual=$(hub_backup --output "$delayed_backup")
assert_contains "$actual" '离线备份已创建' 'backup waits for a delayed Hub health endpoint'
assert_eq active "$(cat "$service_state")" 'delayed Hub restart remains active'
unset VPS_TEST_HEALTH_DELAY_ATTEMPTS

reset_target
printf 'inactive\n' > "$service_state"
inactive_backup="$VPS_BESZEL_HUB_BACKUP_DIR/inactive.tar.gz"
hub_backup --output "$inactive_backup" >/dev/null
assert_eq inactive "$(cat "$service_state")" 'backup preserves an originally inactive service'
if grep -q '^start ' "$systemctl_log"; then
    fail 'backup must not start an originally inactive Hub'
else
    pass 'backup does not start an originally inactive Hub'
fi

reset_target
failed_backup="$VPS_BESZEL_HUB_BACKUP_DIR/failed.tar.gz"
actual=$(
    cp() { return 1; }
    hub_backup --output "$failed_backup" 2>&1
)
assert_eq 40 "$?" 'backup copy failure returns apply failure status'
assert_contains "$actual" '原服务状态已恢复' 'backup failure explains service recovery'
assert_eq active "$(cat "$service_state")" 'backup failure restores the active service'
if [[ ! -e "$failed_backup" && ! -e "$failed_backup.sha256" ]]; then
    pass 'backup failure leaves no publishable partial archive'
else
    fail 'backup failure must clean partial output'
fi

reset_target
good_archive=$(create_bundle good new)
actual=$(hub_restore --archive "$good_archive")
assert_contains "$actual" '已恢复，并通过本机健康验证' 'restore reports end-to-end local verification'
assert_eq new "$(cat "$BESZEL_HUB_DATA_DIR/value")" 'restore activates imported Hub data'
assert_eq active "$(cat "$service_state")" 'restore leaves the verified Hub active'
original_archive=$(find "$BESZEL_HUB_STATE_DIR/transactions" \
    -type f -name original-data.tar.gz -print -quit)
assert_file_exists "$original_archive" 'restore preserves the target original data snapshot'
assert_eq old "$(tar -xOzf "$original_archive" ./value)" \
    'target snapshot contains the pre-restore data'
commands=$(cat "$systemctl_log")
assert_contains "$commands" 'stop beszel-test.service' 'restore stops the target before switching data'
assert_contains "$commands" 'start beszel-test.service' 'restore starts the target for verification'

reset_target
delayed_restore_archive=$(create_bundle delayed-restore new-delayed)
export VPS_TEST_HEALTH_DELAY_ATTEMPTS=2
actual=$(hub_restore --archive "$delayed_restore_archive")
assert_contains "$actual" '已恢复，并通过本机健康验证' \
    'restore waits for a Hub that becomes healthy after startup'
assert_eq new-delayed "$(cat "$BESZEL_HUB_DATA_DIR/value")" \
    'delayed startup commits restored data instead of compensating it'
assert_eq active "$(cat "$service_state")" \
    'delayed startup leaves the Hub active'
unset VPS_TEST_HEALTH_DELAY_ATTEMPTS

reset_target
bad_checksum_archive=$(create_bundle bad-checksum new-checksum)
printf '%064d  %s\n' 0 "$(basename -- "$bad_checksum_archive")" > "$bad_checksum_archive.sha256"
actual=$(hub_restore --archive "$bad_checksum_archive" 2>&1)
assert_eq 30 "$?" 'restore rejects a checksum mismatch as preflight failure'
assert_contains "$actual" 'SHA-256 不匹配' 'checksum mismatch is explained'
assert_eq old "$(cat "$BESZEL_HUB_DATA_DIR/value")" 'checksum mismatch preserves target data'
assert_eq '' "$(cat "$systemctl_log")" 'checksum mismatch occurs before service mutation'

reset_target
unsafe_root="$test_root/unsafe-root"
mkdir -p "$unsafe_root/other"
printf 'bad\n' > "$unsafe_root/other/file"
unsafe_archive="$test_root/unsafe.tar.gz"
tar -czf "$unsafe_archive" -C "$unsafe_root" other
sha256sum "$unsafe_archive" > "$unsafe_archive.sha256"
actual=$(hub_restore --archive "$unsafe_archive" 2>&1)
assert_eq 30 "$?" 'restore rejects paths outside the backup format root'
assert_contains "$actual" '允许目录之外' 'unsafe path rejection is explicit'
assert_eq old "$(cat "$BESZEL_HUB_DATA_DIR/value")" 'unsafe archive preserves target data'
assert_eq '' "$(cat "$systemctl_log")" 'unsafe archive is rejected before stopping the Hub'

reset_target
link_root="$test_root/link-root"
mkdir -p "$link_root/beszel_data"
printf '%s\n' "format=$BESZEL_HUB_FORMAT" > "$link_root/manifest"
ln -s /etc/passwd "$link_root/beszel_data/escape"
link_archive="$test_root/link.tar.gz"
tar -czf "$link_archive" -C "$link_root" manifest beszel_data
sha256sum "$link_archive" > "$link_archive.sha256"
actual=$(hub_restore --archive "$link_archive" 2>&1)
assert_eq 30 "$?" 'restore rejects symbolic links'
assert_contains "$actual" '链接或特殊文件' 'link rejection is explicit'
assert_eq old "$(cat "$BESZEL_HUB_DATA_DIR/value")" 'link archive preserves target data'
assert_eq '' "$(cat "$systemctl_log")" 'link archive is rejected before stopping the Hub'

reset_target
failing_archive=$(create_bundle health-failure new-unhealthy)
export VPS_TEST_HEALTH_FAIL_ON_NEW=yes
actual=$(hub_restore --archive "$failing_archive" 2>&1)
assert_eq 50 "$?" 'post-restore health failure returns verification failure'
assert_contains "$actual" '原数据和服务已自动恢复' 'health failure reports automatic compensation'
assert_eq old "$(cat "$BESZEL_HUB_DATA_DIR/value")" 'health failure restores original target data'
assert_eq active "$(cat "$service_state")" 'health failure restores the original active service'
unset VPS_TEST_HEALTH_FAIL_ON_NEW

reset_target
actual=$(hub_verify)
assert_contains "$actual" '本机健康接口已通过验证' 'verify checks service and local health endpoint'
printf 'inactive\n' > "$service_state"
if hub_verify >/dev/null 2>&1; then
    fail 'verify must reject an inactive Hub service'
else
    assert_eq 50 "$?" 'inactive Hub verification returns verification failure'
fi

reset_target
mkdir -p "$VPS_BESZEL_HUB_BACKUP_DIR"
printf 'rclone test config\n' > "$VPS_BESZEL_HUB_RCLONE_CONFIG"
chmod 600 "$VPS_BESZEL_HUB_RCLONE_CONFIG"
actual=$(hub_onedrive_roundtrip --remote vps-onedrive-crypt --path roundtrip-tests)
assert_contains "$actual" '已完成回读和 SHA-256 校验' \
    'OneDrive test reports a verified encrypted round trip'
assert_contains "$actual" 'Beszel Hub 本机健康验证: 通过' \
    'OneDrive test re-verifies the local Hub after backup'
onedrive_backup=$(find "$VPS_BESZEL_HUB_BACKUP_DIR" -maxdepth 1 \
    -type f -name 'beszel-hub-onedrive-*.tar.gz' -print -quit)
assert_file_exists "$onedrive_backup" 'OneDrive test preserves the local source backup'
assert_file_exists "$remote_store/$(basename -- "$onedrive_backup")" \
    'OneDrive test uploads the archive through the crypt remote'
if [[ "$actual" == *'token'* || "$actual" == *'password'* ]]; then
    fail 'OneDrive test must not print credential fields'
else
    pass 'OneDrive test output does not expose credential fields'
fi

reset_target
printf 'active\n' > "$service_state"
actual=$(hub_onedrive_roundtrip --remote unencrypted 2>&1)
assert_eq 30 "$?" 'OneDrive test rejects a direct unencrypted remote'
assert_contains "$actual" '不是 rclone crypt' \
    'unencrypted remote rejection explains the client-side encryption requirement'
assert_eq '' "$(cat "$systemctl_log")" \
    'remote validation occurs before stopping the Hub for backup'

reset_target
export VPS_TEST_RCLONE_TAMPER=yes
rm -f -- "$VPS_BESZEL_HUB_BACKUP_DIR"/beszel-hub-onedrive-*.tar.gz \
    "$VPS_BESZEL_HUB_BACKUP_DIR"/beszel-hub-onedrive-*.tar.gz.sha256
actual=$(hub_onedrive_roundtrip --remote vps-onedrive-crypt 2>&1)
assert_eq 50 "$?" 'OneDrive test rejects a damaged round-trip download'
assert_contains "$actual" 'SHA-256 校验失败' \
    'damaged round-trip data is reported as a verification failure'
assert_eq active "$(cat "$service_state")" \
    'round-trip verification failure leaves the Hub active'
unset VPS_TEST_RCLONE_TAMPER

reset_target
rm -f -- "$VPS_BESZEL_HUB_BACKUP_DIR"/beszel-hub-onedrive-*.tar.gz \
    "$VPS_BESZEL_HUB_BACKUP_DIR"/beszel-hub-onedrive-*.tar.gz.sha256
actual=$(hub_onedrive_schedule_enable --remote vps-onedrive-crypt \
    --path scheduled --time 04:30 --timezone Asia/Shanghai)
assert_contains "$actual" '定时备份已启用' \
    'OneDrive schedule enable reports the active timer'
assert_file_exists "$BESZEL_HUB_ONEDRIVE_CONFIG" \
    'OneDrive schedule stores its non-secret settings'
assert_file_exists "$BESZEL_HUB_ONEDRIVE_SERVICE" \
    'OneDrive schedule installs a module-owned oneshot service'
assert_file_exists "$BESZEL_HUB_ONEDRIVE_TIMER" \
    'OneDrive schedule installs a module-owned timer'
schedule_timer=$(cat "$BESZEL_HUB_ONEDRIVE_TIMER")
assert_contains "$schedule_timer" 'OnCalendar=*-*-* 04:30:00 Asia/Shanghai' \
    'OneDrive schedule records the explicit local time and timezone'
assert_contains "$schedule_timer" 'RandomizedDelaySec=10min' \
    'OneDrive schedule spreads daily cloud requests'
schedule_service=$(cat "$BESZEL_HUB_ONEDRIVE_SERVICE")
assert_contains "$schedule_service" 'onedrive-run --yes' \
    'scheduled service reuses the verified round-trip backup path'
assert_eq enabled "$(cat "$timer_enabled")" 'OneDrive schedule enables its timer'
assert_eq active "$(cat "$timer_state")" 'OneDrive schedule starts its timer'
if find "$VPS_BESZEL_HUB_BACKUP_DIR" -maxdepth 1 -type f \
    -name 'beszel-hub-onedrive-*.tar.gz' -print -quit | grep -q .; then
    fail 'enabling the timer must not run an immediate backup'
else
    pass 'enabling the timer does not run an immediate backup'
fi
actual=$(hub_onedrive_schedule_status)
assert_contains "$actual" '定时器启用: enabled' \
    'OneDrive schedule status reports enablement'
assert_contains "$actual" '上次服务结果: success' \
    'OneDrive schedule status reports the last service result'
actual=$(hub_onedrive_scheduled_run)
assert_contains "$actual" 'SHA-256 校验' \
    'scheduled run performs a verified cloud round trip'
assert_contains "$(cat "$BESZEL_HUB_BACKUP_RESULT")" 'result=success' \
    'scheduled run records a successful result'
hub_backup_health_check
assert_eq 0 "$?" 'backup health check accepts a fresh verified success'
cp "$BESZEL_HUB_BACKUP_RESULT" "$test_root/valid-backup-result"
printf 'result=success\nexit_code=0\ncompleted_utc=invalid\n' > "$BESZEL_HUB_BACKUP_RESULT"
actual=$(hub_backup_health_check 2>&1)
assert_eq 40 "$?" 'backup health check rejects malformed result content'
cp "$test_root/valid-backup-result" "$BESZEL_HUB_BACKUP_RESULT"
mv "$BESZEL_HUB_BACKUP_RESULT" "$test_root/moved-backup-result"
ln -s "$test_root/moved-backup-result" "$BESZEL_HUB_BACKUP_RESULT"
actual=$(hub_backup_health_check 2>&1)
assert_eq 40 "$?" 'backup health check rejects a symlinked result file'
rm "$BESZEL_HUB_BACKUP_RESULT"
mv "$test_root/moved-backup-result" "$BESZEL_HUB_BACKUP_RESULT"
touch -t 202001010000 "$BESZEL_HUB_BACKUP_RESULT"
actual=$(hub_backup_health_check 2>&1)
assert_eq 40 "$?" 'backup health check rejects a stale success'
assert_contains "$actual" '已过期' 'stale backup result is explained'
touch "$BESZEL_HUB_BACKUP_RESULT"
printf 'disabled\n' > "$timer_enabled"
actual=$(hub_backup_health_check 2>&1)
assert_eq 40 "$?" 'backup health check detects a disabled timer'
printf 'enabled\n' > "$timer_enabled"
hub_backup_health_check
assert_eq 0 "$?" 'backup health check recovers after timer is re-enabled'
assert_contains "$(hub_retention_preview)" '当前目录已验证: 1 份；达到过期条件: 0 份' \
    'retention preview counts only verified pairs and keeps the minimum'
export VPS_TEST_RCLONE_FAIL=yes
actual=$(hub_onedrive_scheduled_run 2>&1)
assert_eq 40 "$?" 'scheduled run reports a cloud upload failure'
assert_contains "$(cat "$BESZEL_HUB_BACKUP_RESULT")" 'result=failure' \
    'scheduled run records a failed result'
actual=$(hub_backup_health_check 2>&1)
assert_eq 40 "$?" 'backup health check rejects a recorded backup failure'
assert_contains "$actual" '未成功' 'recorded backup failure is explained'
assert_contains "$(hub_onedrive_schedule_status)" '上次备份 result: failure' \
    'schedule status exposes the last backup failure'
unset VPS_TEST_RCLONE_FAIL
actual=$(hub_onedrive_schedule_disable)
assert_contains "$actual" '配置和已有备份保持不变' \
    'OneDrive schedule disable preserves settings and backups'
assert_eq disabled "$(cat "$timer_enabled")" 'OneDrive schedule disables its timer'
assert_eq inactive "$(cat "$timer_state")" 'OneDrive schedule stops its timer'
assert_file_exists "$BESZEL_HUB_ONEDRIVE_CONFIG" \
    'disabled OneDrive schedule retains its settings'

reset_target
printf 'external unit\n' > "$BESZEL_HUB_ONEDRIVE_SERVICE"
actual=$(hub_onedrive_schedule_enable --remote vps-onedrive-crypt 2>&1)
assert_eq 30 "$?" 'OneDrive schedule refuses an unowned systemd unit'
assert_contains "$actual" '拒绝覆盖非平台所有' \
    'OneDrive schedule explains the ownership conflict'
assert_eq '' "$(cat "$systemctl_log")" \
    'ownership conflict stops before systemd mutation'

reset_target
export VPS_TEST_TIMER_ENABLE_FAIL=yes
actual=$(hub_onedrive_schedule_enable --remote vps-onedrive-crypt 2>&1)
assert_eq 40 "$?" 'OneDrive schedule surfaces a timer enable failure'
assert_contains "$actual" '已尝试恢复原定时状态' \
    'OneDrive schedule reports compensation after enable failure'
if [[ ! -e "$BESZEL_HUB_ONEDRIVE_CONFIG" && \
      ! -e "$BESZEL_HUB_ONEDRIVE_SERVICE" && \
      ! -e "$BESZEL_HUB_ONEDRIVE_TIMER" ]]; then
    pass 'failed first-time schedule enable removes only its new files'
else
    fail 'failed first-time schedule enable must restore the absent baseline'
fi
unset VPS_TEST_TIMER_ENABLE_FAIL

finish_tests
