# Debian 12 Validation Record

## Scope

This record summarizes a manual integration run completed across 2026-08-19 and 2026-08-20 against commit `44acb0c7cb83569dc1a7ee8b07e70649dab0b0a8`. Host and client addresses are intentionally omitted.

The target was Debian 12 with a 6.1 kernel, systemd, `ssh.service`, an existing UFW installation, and an installed but initially broken Fail2Ban service. Automated project tests also passed on the target. ShellCheck was not installed on the VPS, but the same commit passed ShellCheck and both GitHub CI runs.

## Verified workflows

### SSH detection

- Detected the active default SSH port 22 from the current session, listener, and effective OpenSSH configuration.
- Added a temporary OpenSSH drop-in with port 32876 while retaining port 22.
- Detected and deduplicated both ports as `22,32876`.
- Established a real second SSH connection on port 32876.
- Preserved the current custom session port instead of falling back to 22.
- Removed the port 22 declaration and verified a custom-only configuration listening on port 32876.
- Established a new real SSH connection while only port 32876 was listening.
- Confirmed that SSH detection, the firewall plan, Fail2Ban, and the doctor used only port 32876 and did not reintroduce port 22.
- Removed the temporary drop-in and returned cleanly to port 22.

### UFW

- Preserved an active firewall and every pre-existing user rule.
- Applied and verified the default-port workflow without adding unrelated web rules.
- Repeated apply successfully without duplicating existing rules.
- Added only `32876/tcp` when the temporary SSH port became active.
- Verified a new SSH connection through the newly added rule.
- Removed only the module-added custom-port rule during cleanup.
- Kept UFW active and retained every rule that existed before the test.
- Disabled UFW before an apply, then verified that apply activated it and rollback restored the original inactive state without deleting stored user rules.
- Reapplied the module after the inactive-state rollback and returned the host to an active, verified firewall state.

### Fail2Ban

- Detected that Fail2Ban was installed but its service had failed.
- Identified the Debian minimal-image conflict between an inherited `/var/log/auth.log` path and systemd journal logging.
- Validated the generated configuration against a temporary copy without writing `/etc` or changing service state.
- Applied, started, and verified the `sshd` jail with port 22.
- Applied and verified the jail with both ports `22,32876`.
- Applied and verified the jail with custom port 32876 only.
- Preserved the distribution/user-owned `/etc/fail2ban/jail.local` byte-for-byte.
- Restored the previous enabled/active service state and removed the module-owned drop-in on rollback.
- Reapplied the final single-port configuration and ended with Fail2Ban active.
- After a host reboot, confirmed that the service and `sshd` jail were active and that real hostile login attempts had been banned.

### Reboot persistence

- Rebooted the VPS after applying the security modules.
- Confirmed that `ssh.service`, `ufw.service`, and `fail2ban.service` were enabled and active after boot.
- Confirmed that OpenSSH listened on the expected port, UFW retained all pre-existing rules, and the Fail2Ban control socket and `sshd` jail were healthy.
- Re-ran firewall verification, Fail2Ban verification, and `vps doctor`; all passed.

### Final state

- OpenSSH listens on port 22 only.
- UFW is active and contains no temporary integration-test rule.
- Fail2Ban is active and its `sshd` jail is verified.
- The module-owned Fail2Ban configuration protects port 22 and the original `jail.local` remains unchanged.
- `vps doctor` reports no blocking security-initialization issue.

## Defects discovered during the run

1. The doctor originally treated an installed Fail2Ban binary as a healthy service.
2. The Fail2Ban rollback originally did not restore the prior enabled/active service state.
3. A user `jail.local` could leave an inherited file `logpath` active when the module selected the systemd backend.
4. Fail2Ban verification could run before its control socket became ready and trigger a false rollback.
5. Firewall rollback could delete a module-added rule still used by the current SSH session.

All five defects have regression coverage in the development branch. The fifth fix was added after the original active-session rollback scenario had already been cleaned up; its exact live rerun remains scheduled for a disposable host, while automated tests cover active-session retention and deferred cleanup.

## Remaining validation gaps

- `ssh.socket` activation;
- Debian with rsyslog and `/var/log/auth.log`;
- Debian 11, Debian 13, Ubuntu 22.04, and Ubuntu 24.04;
- a custom-only port declared directly in the main `sshd_config` rather than a drop-in;
- controlled Fail2Ban ban/unban and recovery testing;
- a live rerun of firewall rollback while the current session still uses the module-added port;
- invalid-candidate and interrupted-operation fault injection.

Until these gaps are addressed, Debian 12 is classified as compatible and manually validated for the workflows above, not fully supported under the complete compatibility policy.
