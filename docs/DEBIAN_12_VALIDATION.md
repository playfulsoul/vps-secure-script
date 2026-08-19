# Debian 12 Validation Record

## Scope

This record summarizes a manual integration run completed on 2026-08-19 against commit `44acb0c7cb83569dc1a7ee8b07e70649dab0b0a8`. Host and client addresses are intentionally omitted.

The target was Debian 12 with a 6.1 kernel, systemd, `ssh.service`, an already-active UFW installation, and an installed but initially broken Fail2Ban service. Automated project tests also passed on the target. ShellCheck was not installed on the VPS, but the same commit passed ShellCheck and both GitHub CI runs.

## Verified workflows

### SSH detection

- Detected the active default SSH port 22 from the current session, listener, and effective OpenSSH configuration.
- Added a temporary OpenSSH drop-in with port 32876 while retaining port 22.
- Detected and deduplicated both ports as `22,32876`.
- Established a real second SSH connection on port 32876.
- Preserved the current custom session port instead of falling back to 22.
- Removed the temporary drop-in and returned cleanly to port 22.

### UFW

- Preserved an active firewall and every pre-existing user rule.
- Applied and verified the default-port workflow without adding unrelated web rules.
- Repeated apply successfully without duplicating existing rules.
- Added only `32876/tcp` when the temporary SSH port became active.
- Verified a new SSH connection through the newly added rule.
- Removed only the module-added custom-port rule during cleanup.
- Kept UFW active and retained every rule that existed before the test.

### Fail2Ban

- Detected that Fail2Ban was installed but its service had failed.
- Identified the Debian minimal-image conflict between an inherited `/var/log/auth.log` path and systemd journal logging.
- Validated the generated configuration against a temporary copy without writing `/etc` or changing service state.
- Applied, started, and verified the `sshd` jail with port 22.
- Applied and verified the jail with both ports `22,32876`.
- Preserved the distribution/user-owned `/etc/fail2ban/jail.local` byte-for-byte.
- Restored the previous enabled/active service state and removed the module-owned drop-in on rollback.
- Reapplied the final single-port configuration and ended with Fail2Ban active.

### Final state

- OpenSSH listens on port 22 only.
- UFW is active and contains no temporary integration-test rule.
- Fail2Ban is active and its `sshd` jail is verified.
- `vps doctor` reports no blocking security-initialization issue.

## Defects discovered during the run

1. The doctor originally treated an installed Fail2Ban binary as a healthy service.
2. The Fail2Ban rollback originally did not restore the prior enabled/active service state.
3. A user `jail.local` could leave an inherited file `logpath` active when the module selected the systemd backend.
4. Fail2Ban verification could run before its control socket became ready and trigger a false rollback.
5. Firewall rollback could delete a module-added rule still used by the current SSH session.

All five defects have regression coverage in the development branch. The fifth fix was added after the temporary custom-port rule had already been cleaned up; its exact live rollback scenario remains scheduled for a disposable-host rerun, while automated tests cover active-session retention and deferred cleanup.

## Remaining validation gaps

- reboot persistence;
- an initially inactive UFW installation;
- a custom-only SSH port with no port 22 listener;
- `ssh.socket` activation;
- Debian with rsyslog and `/var/log/auth.log`;
- Debian 11, Debian 13, Ubuntu 22.04, and Ubuntu 24.04;
- intentional Fail2Ban ban/unban behavior;
- invalid-candidate and interrupted-operation fault injection.

Until these gaps are addressed, Debian 12 is classified as compatible and manually validated for the workflows above, not fully supported under the complete compatibility policy.
