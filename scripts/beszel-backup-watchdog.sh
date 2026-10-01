#!/usr/bin/env bash

set -u

result_file=${VPS_BESZEL_BACKUP_RESULT:-/var/lib/vps-secure/modules/applications-beszel-hub/onedrive-last-result}
timer_unit=vps-secure-beszel-hub-onedrive.timer
backup_unit=vps-secure-beszel-hub-onedrive.service
max_age=${VPS_BESZEL_BACKUP_MAX_AGE_SECONDS:-100800}
interval=${VPS_BESZEL_BACKUP_WATCH_INTERVAL_SECONDS:-300}

check_backup() {
    local line modified now service_result lines=()
    [[ "$result_file" == /* && "$result_file" != / && ! "$result_file" =~ [[:cntrl:]] ]] || return 64
    [[ "$max_age" =~ ^[0-9]+$ ]] && (( max_age >= 3600 && max_age <= 604800 )) || return 64
    [[ -f "$result_file" && ! -L "$result_file" ]] || {
        printf 'backup_result_missing_or_unsafe\n' >&2
        return 40
    }
    while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("$line")
        (( ${#lines[@]} <= 3 )) || break
    done < "$result_file"
    [[ ${#lines[@]} -eq 3 && ${lines[0]} == result=success && \
       ${lines[1]} == exit_code=0 && \
       ${lines[2]} =~ ^completed_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        printf 'backup_result_failed_or_invalid\n' >&2
        return 40
    }
    modified=$(stat -c %Y "$result_file" 2>/dev/null || stat -f %m "$result_file") || return 40
    now=$(date +%s) || return 40
    (( modified <= now + 300 && now - modified <= max_age )) || {
        printf 'backup_result_stale\n' >&2
        return 40
    }
    if ! systemctl is-enabled --quiet "$timer_unit" || \
       ! systemctl is-active --quiet "$timer_unit"; then
        printf 'backup_timer_inactive\n' >&2
        return 40
    fi
    service_result=$(systemctl show "$backup_unit" -p Result --value 2>/dev/null) || return 40
    [[ "$service_result" == success ]] || {
        printf 'backup_service_failed\n' >&2
        return 40
    }
}

case ${1:-} in
    check)
        [[ $# -eq 1 ]] || exit 64
        check_backup
        ;;
    watch)
        [[ $# -eq 1 && "$interval" =~ ^[0-9]+$ ]] && \
            (( interval >= 1 && interval <= 3600 )) || exit 64
        while :; do
            check_backup || exit $?
            sleep "$interval" || exit $?
        done
        ;;
    *) exit 64 ;;
esac
