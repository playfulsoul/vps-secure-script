#!/usr/bin/env bash
set -eu
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$root" <<'PY'
import os, pathlib, stat, subprocess, sys, tempfile, unittest
project=pathlib.Path(sys.argv.pop())
class ShortcutTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.base=pathlib.Path(self.tmp.name); self.home=self.base/'home'; self.home.mkdir()
        self.desktop=self.home/'中文桌面'; self.src=self.base/'official.desktop'; self.app=self.base/'managed.desktop'
        self.content='[Desktop Entry]\nType=Application\nName=Firefox\nExec=/snap/bin/firefox %u\nIcon=/snap/firefox/current/default256.png\nTerminal=false\n'
        self.src.write_text(self.content); self.src.chmod(0o644)
        self.bin=self.base/'bin'; self.bin.mkdir(); self.calls=self.base/'gio-calls'
        script=(project/'modules/builtin/applications-remote-desktop/firefox-shortcut.sh').read_text()
        script=script.replace('/var/lib/snapd/desktop/applications/firefox_firefox.desktop /usr/share/applications/firefox-esr.desktop',str(self.src)+' '+str(self.base/'missing.desktop'))
        script=script.replace('application=/usr/share/applications/vps-secure-firefox.desktop','application='+str(self.app))
        self.script=self.base/'helper.sh'; self.script.write_text(script)
        self.env=dict(os.environ,HOME=str(self.home),PATH=str(self.bin)+':'+os.environ['PATH'],TEST_DESKTOP=str(self.desktop),TEST_CALLS=str(self.calls),TEST_SOURCE=str(self.src),TEST_APP=str(self.app))
        self.env.pop('DBUS_SESSION_BUS_ADDRESS',None)
        self.command('xdg-user-dir','#!/bin/sh\nprintf "%s\\n" "$TEST_DESKTOP"\n')
        self.command('stat', '#!'+sys.executable+'\nimport os,sys,stat\np=sys.argv[-1]; s=os.stat(p); owner=s.st_uid\nif p==os.environ["TEST_SOURCE"]: owner=int(os.environ.get("TEST_SOURCE_OWNER","0"))\nif p==os.environ["TEST_APP"]: owner=int(os.environ.get("TEST_APP_OWNER","0"))\nprint(owner if "%u" in sys.argv else oct(stat.S_IMODE(s.st_mode))[2:])\n')
        self.command('readlink','#!'+sys.executable+'\nimport os,sys\nprint(os.path.realpath(sys.argv[-1]))\n')
        self.command('chmod','#!'+sys.executable+'\nimport os,sys,subprocess\na=[v for v in sys.argv[1:] if v!="--"]; sys.exit(subprocess.call(["/bin/chmod"]+a))\n')
        self.command('gio','#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_CALLS"\nexit 99\n')
        p=subprocess.run(['bash',str(self.script),'--application'],env=self.env,text=True,capture_output=True)
        self.assertEqual(p.returncode,0,p.stderr); self.app.write_text(p.stdout); self.app.chmod(0o644)
    def command(self,name,text):
        path=self.bin/name; path.write_text(text); path.chmod(0o755)
    def run_helper(self):
        p=subprocess.run(['bash',str(self.script)],env=self.env,text=True,capture_output=True)
        self.assertIn(p.returncode,(0,10),p.stderr); self.assertFalse(self.calls.exists(),'must not use GVFS metadata or change trust'); return p.stderr
    def target(self): return self.desktop/'Firefox.desktop'
    def test_create_localized_native_link_without_bus_or_gvfs(self):
        self.run_helper(); text=self.target().read_text(); self.assertIn('Type=Link\n',text)
        self.assertIn('URL='+str(self.app),text); self.assertNotIn('Exec=',text)
        self.assertIn('Icon=/snap/firefox/current/default256.png',text)
        self.assertEqual(stat.S_IMODE(self.target().stat().st_mode),0o644)
    def test_existing_official_copy_converts_to_native_link(self):
        self.desktop.mkdir(); self.target().write_text(self.content); self.run_helper()
        self.assertIn('Type=Link',self.target().read_text())
    def test_existing_native_link_is_idempotent(self):
        self.run_helper(); before=self.target().stat().st_mtime_ns; self.run_helper()
        self.assertEqual(before,self.target().stat().st_mtime_ns)
    def test_custom_file_is_preserved(self):
        self.desktop.mkdir(); self.target().write_text('user customization'); self.target().chmod(0o600)
        self.run_helper(); self.assertEqual(self.target().read_text(),'user customization')
        self.assertEqual(stat.S_IMODE(self.target().stat().st_mode),0o600)
    def test_source_update_does_not_overwrite_old_user_icon(self):
        self.desktop.mkdir(); self.target().write_text(self.content)
        self.src.write_text(self.content.replace('Name=Firefox','Name=Firefox New'))
        self.run_helper(); self.assertEqual(self.target().read_text(),self.content)
    def test_target_symlink_is_preserved(self):
        self.desktop.mkdir(); other=self.home/'other'; other.write_text(self.content); self.target().symlink_to(other)
        self.run_helper(); self.assertTrue(self.target().is_symlink())
    def test_desktop_symlink_is_refused(self):
        other=self.base/'outside'; other.mkdir(); self.desktop.symlink_to(other)
        self.run_helper(); self.assertFalse((other/'Firefox.desktop').exists())
    def test_desktop_outside_home_is_refused(self):
        self.env['TEST_DESKTOP']=str(self.base/'outside'); self.run_helper(); self.assertFalse(self.target().exists())
    def test_desktop_traversal_is_refused(self):
        self.env['TEST_DESKTOP']=str(self.home)+'/../outside'; self.run_helper(); self.assertFalse(self.target().exists())
    def test_disabled_desktop_is_respected(self):
        self.env['TEST_DESKTOP']=str(self.home); self.run_helper(); self.assertFalse((self.home/'Firefox.desktop').exists())
    def test_symlinked_official_source_is_refused(self):
        other=self.base/'other'; self.src.rename(other); self.src.symlink_to(other); self.run_helper(); self.assertFalse(self.target().exists())
    def test_writable_official_source_is_refused(self):
        self.src.chmod(0o666); self.run_helper(); self.assertFalse(self.target().exists())
    def test_non_root_official_source_is_refused(self):
        self.env['TEST_SOURCE_OWNER']='99999'; self.run_helper(); self.assertFalse(self.target().exists())
    def test_arbitrary_exec_is_refused(self):
        self.src.write_text(self.content.replace('/snap/bin/firefox %u','sh -c evil')); self.run_helper(); self.assertFalse(self.target().exists())
    def test_all_four_observed_official_exec_entries_are_allowed(self):
        self.src.write_text(self.content+'\n[Desktop Action new-window]\nExec=/snap/bin/firefox --new-window %u\n[Desktop Action private-window]\nExec=/snap/bin/firefox --private-window %u\n[Desktop Action profile-manager]\nExec=/snap/bin/firefox -ProfileManager\n')
        self.run_helper(); self.assertTrue(self.target().is_file())
    def test_snap159_double_dash_profile_manager_is_allowed(self):
        self.src.write_text(self.content+'\n[Desktop Action new-window]\nExec=/snap/bin/firefox --new-window %u\n[Desktop Action private-window]\nExec=/snap/bin/firefox --private-window %u\n[Desktop Action profile-manager]\nExec=/snap/bin/firefox --ProfileManager\n')
        self.run_helper(); self.assertTrue(self.target().is_file())
    def test_malicious_secondary_action_is_refused(self):
        self.src.write_text(self.content+'\n[Desktop Action Extra]\nExec=sh -c evil\n'); self.run_helper(); self.assertFalse(self.target().exists())
    def test_conflicting_terminal_key_is_refused(self):
        self.src.write_text(self.content+'Terminal=true\n'); self.run_helper(); self.assertFalse(self.target().exists())
    def test_modified_managed_application_is_refused(self):
        self.app.write_text('custom'); self.run_helper(); self.assertFalse(self.target().exists())
    def test_symlinked_managed_application_is_refused(self):
        other=self.base/'other'; self.app.rename(other); self.app.symlink_to(other); self.run_helper(); self.assertFalse(self.target().exists())
    def test_writable_managed_application_is_refused(self):
        self.app.chmod(0o666); self.run_helper(); self.assertFalse(self.target().exists())
    def test_other_owner_managed_application_is_refused(self):
        self.env['TEST_APP_OWNER']='99999'; self.run_helper(); self.assertFalse(self.target().exists())
    def test_icon_revision_update_keeps_existing_link_conservatively(self):
        self.run_helper(); original=self.target().read_text()
        self.src.write_text(self.content.replace('/snap/firefox/current/default256.png','/snap/firefox/999/default256.png'))
        app=subprocess.run(['bash',str(self.script),'--application'],env=self.env,text=True,capture_output=True)
        self.assertEqual(app.returncode,0); self.app.write_text(app.stdout)
        self.run_helper(); self.assertEqual(self.target().read_text(),original)
        self.assertIn('URL='+str(self.app),original)  # Launch target stays stable; old icon is intentionally preserved.
    def test_later_user_edit_is_never_overwritten(self):
        self.run_helper(); self.target().write_text('user-edit'); self.run_helper(); self.assertEqual(self.target().read_text(),'user-edit')
unittest.main()
PY
export VPS_PLATFORM_ROOT="$root"
source "$root/tests/test_helper.sh"
source "$root/modules/builtin/applications-remote-desktop/module.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
RD_LIB_DIR="$fixture/lib"
RD_CONFIG_DIR="$fixture/config"
RD_STATE_FILE="$RD_CONFIG_DIR/state"
RD_FIREFOX_APPLICATION="$fixture/applications/vps-secure-firefox.desktop"
mkdir -p "$RD_LIB_DIR" "$RD_CONFIG_DIR"
: > "$fixture/paths"
RD_PROFILE=lxqt RD_BROWSER=firefox
vps_platform_id() { printf 'ubuntu\n'; }
assert_contains "$(rd_selected_packages)" xdg-user-dirs 'LXQt Firefox selects desktop directory support'
if rd_selected_packages | grep -q gvfs; then fail 'must not add GVFS'; else pass 'shortcut needs no GVFS dependency'; fi
rd_write_firefox_shortcut_helper
rd_write_session_script "$fixture/startwm"
assert_contains "$(cat "$fixture/startwm")" 'vps-secure-firefox-shortcut' 'selected LXQt Firefox session runs the helper'
RD_BROWSER=none
rd_write_session_script "$fixture/startwm"
if grep -q vps-secure-firefox-shortcut "$fixture/startwm"; then fail 'none browser must not run helper'; else pass 'none browser does not run helper'; fi
RD_PROFILE=mate RD_BROWSER=firefox
rd_write_session_script "$fixture/startwm"
if grep -q vps-secure-firefox-shortcut "$fixture/startwm"; then fail 'MATE must not run LXQt helper'; else pass 'other desktop does not run helper'; fi
# Fixture replaces only source discovery for privileged entry lifecycle tests.
bash() { if [[ ${2:-} == --application ]]; then printf '[Desktop Entry]\nType=Application\nName=Firefox\nExec=/snap/bin/firefox %%u\nNoDisplay=true\n'; else command bash "$@"; fi; }
stat() { if [[ ${2:-} == %u ]]; then printf '0\n'; else printf '644\n'; fi; }
RD_PROFILE=lxqt RD_BROWSER=firefox
rd_write_firefox_application "$fixture"
assert_eq 0 "$?" 'system application is created with a rollback record'
assert_eq absent "$(rd_path_state "$fixture" firefox-application)" 'absent application baseline is recorded'
assert_eq 10 "$(rd_write_firefox_application "$fixture"; printf '%s' "$?")" 'unchanged system entry is a no-op'
printf 'admin edit\n' > "$RD_FIREFOX_APPLICATION"
result=0; rd_write_firefox_application "$fixture" >/dev/null 2>&1 || result=$?
assert_eq 60 "$result" 'unknown administrator entry is not overwritten'
result=0; rd_restore_firefox_application "$fixture" >/dev/null 2>&1 || result=$?
assert_eq 60 "$result" 'rollback preserves administrator edits'
bash fixture --application > "$RD_FIREFOX_APPLICATION"
rd_restore_firefox_application "$fixture"
if [[ ! -e "$RD_FIREFOX_APPLICATION" ]]; then pass 'rollback removes only its unchanged system application'; else fail 'owned entry remained'; fi
printf 'profile=lxqt\nbrowser=firefox\n' > "$RD_STATE_FILE"
rd_managed_transaction() { printf '%s\n' "$fixture"; }
rd_package_installed() { return 1; }
rd_package_present() { return 1; }
rd_apt_unlocked() { return 0; }
rd_present_packages() { printf 'existing-package\n'; }
vps_apt_update() { return 0; }
vps_apt_install() { return 40; }
rd_record_repair_packages() { : > "$fixture/recorded-after-failure"; }
result=0; rd_repair_firefox_shortcut >/dev/null || result=$?
assert_eq 40 "$result" 'failed component installation retains failure status'
if [[ -f "$fixture/recorded-after-failure" ]]; then pass 'partial installation is recorded for rollback'; else fail 'partial installation ownership was lost'; fi
finish_tests
