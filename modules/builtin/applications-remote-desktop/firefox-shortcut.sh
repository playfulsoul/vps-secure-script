#!/usr/bin/env bash
# Runs only inside the managed user's LXQt session. Never trusts arbitrary files.
set -u
note() { printf 'Firefox 桌面图标：%s\n' "$*" >&2; }
source_file=''
for candidate in /var/lib/snapd/desktop/applications/firefox_firefox.desktop /usr/share/applications/firefox-esr.desktop; do
    [[ -f "$candidate" && ! -L "$candidate" ]] || continue
    [[ $(stat -c %u -- "$candidate" 2>/dev/null) == 0 ]] || continue
    mode=$(stat -c %a -- "$candidate" 2>/dev/null) || continue
    if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 0022) != 0 )); then continue; fi
    [[ $(grep -c '^Type=' "$candidate") == 1 ]] || continue
    grep -Fxq 'Type=Application' "$candidate" || continue
    grep -Fxq 'Terminal=false' "$candidate" || continue
    [[ $(grep '^Terminal=' "$candidate" | sort -u) == 'Terminal=false' ]] || continue
    exec_count=0 valid=yes
    while IFS= read -r entry; do
        [[ "$entry" == Exec=* ]] || continue
        exec_count=$((exec_count + 1))
        if [[ ! "$entry" =~ ^Exec=(env\ BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/firefox_firefox.desktop\ )?(/snap/bin/firefox|firefox-esr|/usr/bin/firefox-esr)(\ (%[uUfF]|--new-window|--private-window|-new-window|-private-window|-ProfileManager|--ProfileManager))*$ ]]; then
            valid=no
        fi
    done < "$candidate"
    [[ "$valid" == yes && "$exec_count" -gt 0 ]] || continue
    source_file=$candidate
    break
done
[[ -n "$source_file" ]] || { note '未找到可核验的官方入口，保留现有文件。'; exit 10; }
application=/usr/share/applications/vps-secure-firefox.desktop
icon=$(awk '
    /^\[/ { main = ($0 == "[Desktop Entry]") }
    main && /^Icon=/ { sub(/^Icon=/, ""); print; exit }
' "$source_file")
[[ -n "$icon" ]] || icon=firefox
emit_application() {
    local executable=/usr/bin/firefox-esr
    [[ "$source_file" != /var/lib/snapd/desktop/applications/firefox_firefox.desktop ]] || executable=/snap/bin/firefox
    printf '[Desktop Entry]\nType=Application\nName=Firefox\nExec=%s %%u\nIcon=%s\nTerminal=false\nNoDisplay=true\nX-VPS-Secure-Managed=firefox-shortcut-v1\n' "$executable" "$icon"
}
case ${1:-} in
    --application) emit_application; exit 0 ;;
    '') ;;
    *) exit 64 ;;
esac
# The system entry is fixed, root owned, and not writable by other users.
[[ -f "$application" && ! -L "$application" && $(stat -c %u -- "$application" 2>/dev/null) == 0 ]] || {
    note '受管应用入口尚未就绪，请运行补齐必要组件。'; exit 0;
}
mode=$(stat -c %a -- "$application" 2>/dev/null) || exit 0
if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 0022) != 0 )); then exit 0; fi
cmp -s "$application" <(emit_application) || { note '应用入口已变化，未创建快捷方式。'; exit 0; }
emit_link() {
    # LXQt recognizes its native application-menu links without executable trust.
    printf '[Desktop Entry]\nType=Link\nName=Firefox\nIcon=%s\nURL=%s\nX-VPS-Secure-Managed=firefox-shortcut-v1\n' "$icon" "$application"
}
command -v xdg-user-dir >/dev/null 2>&1 || { note '缺少桌面目录组件，请运行补齐必要组件。'; exit 0; }
desktop_dir=$(xdg-user-dir DESKTOP 2>/dev/null) || exit 0
[[ "${HOME:-}" == /* && "$desktop_dir" == "$HOME/"* && "$desktop_dir" != "$HOME" ]] || {
    note '桌面目录不在当前主目录内，未创建图标。'; exit 0;
}
home_real=$(readlink -f -- "$HOME") || exit 0
[[ "$desktop_dir" != *'/../'* && "$desktop_dir" != */.. && "$desktop_dir" != *'/./'* ]] || exit 0
current=$desktop_dir
while [[ "$current" != "$HOME" ]]; do
    [[ ! -L "$current" ]] || { note '桌面目录含符号链接，未修改。'; exit 0; }
    current=${current%/*}
    [[ -n "$current" ]] || exit 0
done
[[ -d "$desktop_dir" ]] || mkdir -p -- "$desktop_dir" || exit 0
desktop_real=$(readlink -f -- "$desktop_dir") || exit 0
[[ "$desktop_real" == "$home_real/"* && -O "$desktop_dir" ]] || exit 0
target="$desktop_dir/Firefox.desktop"
[[ ! -L "$target" ]] || { note '同名图标为符号链接，已保留。'; exit 0; }
replace=no
if [[ -e "$target" ]]; then
    [[ -f "$target" && -O "$target" ]] || { note '同名文件不属于当前用户，已保留。'; exit 0; }
    cmp -s "$target" <(emit_link) && exit 0
    cmp -s "$source_file" "$target" || {
        note '同名图标有自定义内容，已保留；可从应用菜单打开 Firefox。'; exit 0;
    }
    replace=yes
fi
temporary=$(mktemp "$desktop_dir/.vps-firefox.XXXXXX") || exit 0
trap 'rm -f -- "$temporary"' EXIT
emit_link > "$temporary" && chmod 644 "$temporary" || exit 0
if [[ "$replace" == yes ]]; then
    # Recheck immediately before replacing an unchanged official copy only.
    [[ ! -L "$target" && -f "$target" && -O "$target" ]] && cmp -s "$source_file" "$target" || exit 0
    mv -f -- "$temporary" "$target" || exit 0
else
    ln -- "$temporary" "$target" 2>/dev/null || { note '目标已变化，未覆盖。'; exit 0; }
    rm -f -- "$temporary"
fi
trap - EXIT
note '已创建原生应用快捷方式；无需信任可执行文件，不改变全局执行或挂载设置。'
