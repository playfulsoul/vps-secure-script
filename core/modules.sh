#!/usr/bin/env bash

vps_manifest_value() {
    local manifest=$1
    local requested_key=$2
    local line key value

    [[ -r "$manifest" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || continue
        key=${line%%=*}
        value=${line#*=}
        if [[ "$key" == "$requested_key" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$manifest"

    return 1
}

vps_validate_manifest() {
    local manifest=$1
    local required key value line
    local seen_keys='|'
    local required_keys=(id name version category entry trust privilege actions)

    [[ -f "$manifest" ]] || {
        printf '模块描述文件不存在: %s\n' "$manifest" >&2
        return 64
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ ! "$line" =~ ^[a-z_]+=[^[:cntrl:]]*$ ]]; then
            printf '模块描述包含无效行: %s\n' "$line" >&2
            return 64
        fi
        key=${line%%=*}
        if [[ "$seen_keys" == *"|$key|"* ]]; then
            printf '模块描述包含重复字段: %s\n' "$key" >&2
            return 64
        fi
        seen_keys+="$key|"
    done < "$manifest"

    for required in "${required_keys[@]}"; do
        value=$(vps_manifest_value "$manifest" "$required" 2>/dev/null || true)
        if [[ -z "$value" ]]; then
            printf '模块描述缺少字段: %s\n' "$required" >&2
            return 64
        fi
    done

    value=$(vps_manifest_value "$manifest" id)
    [[ "$value" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || {
        printf '模块 ID 无效: %s\n' "$value" >&2
        return 64
    }

    value=$(vps_manifest_value "$manifest" version)
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9.-]+)?$ ]] || {
        printf '模块版本无效: %s\n' "$value" >&2
        return 64
    }

    value=$(vps_manifest_value "$manifest" entry)
    [[ "$value" =~ ^[a-zA-Z0-9._-]+$ ]] || {
        printf '模块入口无效: %s\n' "$value" >&2
        return 64
    }

    value=$(vps_manifest_value "$manifest" trust)
    [[ "$value" =~ ^(builtin|official|third-party)$ ]] || {
        printf '模块信任级别无效: %s\n' "$value" >&2
        return 64
    }

    value=$(vps_manifest_value "$manifest" privilege)
    [[ "$value" =~ ^(unprivileged|data-write|system|high-risk|external-root)$ ]] || {
        printf '模块权限级别无效: %s\n' "$value" >&2
        return 64
    }

    value=$(vps_manifest_value "$manifest" actions)
    [[ "$value" =~ ^[a-z]+(,[a-z]+)*$ ]] || {
        printf '模块操作列表无效: %s\n' "$value" >&2
        return 64
    }
    local declared_actions=() action
    IFS=, read -r -a declared_actions <<< "$value"
    for action in "${declared_actions[@]}"; do
        vps_module_action_is_valid "$action" || {
            printf '模块声明了未知操作: %s\n' "$action" >&2
            return 64
        }
    done
}

vps_module_roots() {
    local installed_path=${VPS_INSTALLED_MODULE_DIR:-/usr/local/lib/vps-secure/modules}
    local default_path="$VPS_PLATFORM_ROOT/modules/builtin:$VPS_PLATFORM_ROOT/modules/official:$installed_path"
    local module_path=${VPS_MODULE_PATH:-$default_path}
    local roots=()
    local root

    IFS=: read -r -a roots <<< "$module_path"
    for root in "${roots[@]}"; do
        [[ -n "$root" && -d "$root" ]] && printf '%s\n' "$root"
    done
}

vps_module_manifests() {
    local root

    while IFS= read -r root; do
        find "$root" -mindepth 2 -maxdepth 2 -type f -name module.conf
    done < <(vps_module_roots) | sort
}

vps_module_find() {
    local requested_id=$1
    local manifest id
    local found=''

    while IFS= read -r manifest; do
        vps_validate_manifest "$manifest" >/dev/null 2>&1 || continue
        id=$(vps_manifest_value "$manifest" id)
        [[ "$id" == "$requested_id" ]] || continue
        if [[ -n "$found" ]]; then
            printf '发现重复模块 ID: %s\n' "$requested_id" >&2
            return 64
        fi
        found=$manifest
    done < <(vps_module_manifests)

    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

vps_module_list() {
    local manifest id name version category trust

    while IFS= read -r manifest; do
        if ! vps_validate_manifest "$manifest"; then
            continue
        fi
        id=$(vps_manifest_value "$manifest" id)
        name=$(vps_manifest_value "$manifest" name)
        version=$(vps_manifest_value "$manifest" version)
        category=$(vps_manifest_value "$manifest" category)
        trust=$(vps_manifest_value "$manifest" trust)
        printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$version" "$category" "$trust"
    done < <(vps_module_manifests)
}

vps_module_action_is_valid() {
    case ${1:-} in
        check|plan|preflight|apply|verify|status|backup|rollback|configure|start|stop|uninstall|doctor)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

vps_module_action_changes_state() {
    case ${1:-} in
        apply|backup|rollback|configure|start|stop|uninstall)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

vps_module_declares_action() {
    local manifest=$1 requested=$2 actions action
    local declared_actions=()
    actions=$(vps_manifest_value "$manifest" actions) || return 1
    IFS=, read -r -a declared_actions <<< "$actions"
    for action in "${declared_actions[@]}"; do
        [[ "$action" == "$requested" ]] && return 0
    done
    return 1
}

vps_module_run() {
    local module_id=$1
    local action=$2
    shift 2

    local manifest module_dir entry privilege
    vps_module_action_is_valid "$action" || {
        printf '无效模块操作: %s\n' "$action" >&2
        return 64
    }

    manifest=$(vps_module_find "$module_id") || {
        printf '未找到模块: %s\n' "$module_id" >&2
        return 20
    }
    vps_validate_manifest "$manifest" || return $?
    vps_module_declares_action "$manifest" "$action" || {
        printf '模块 %s 未声明操作: %s\n' "$module_id" "$action" >&2
        return 64
    }

    module_dir=$(dirname -- "$manifest")
    entry=$(vps_manifest_value "$manifest" entry)
    privilege=$(vps_manifest_value "$manifest" privilege)

    if vps_module_action_changes_state "$action" && \
       [[ "$privilege" =~ ^(system|high-risk|external-root)$ ]] && \
       (( EUID != 0 )); then
        printf '模块 %s 的 %s 操作需要 root 权限。\n' "$module_id" "$action" >&2
        return 30
    fi

    [[ -x "$module_dir/$entry" ]] || {
        printf '模块入口不可执行: %s\n' "$module_dir/$entry" >&2
        return 64
    }

    VPS_MODULE_ID="$module_id" \
    VPS_MODULE_DIR="$module_dir" \
    VPS_PLATFORM_ROOT="$VPS_PLATFORM_ROOT" \
        "$module_dir/$entry" "$action" "$@"
}
