# Ubuntu 22.04 Validation Record

## Scope

This record summarizes a manual integration run completed on 2026-08-20 against commit `811c158f5fb433814e3bb816710788de6257e724`. Host and client addresses are intentionally omitted.

The target was Ubuntu 22.04 with systemd, `ssh.service`, Docker, an already-active UFW installation with multiple pre-existing rules, rsyslog and `/var/log/auth.log`, and no Fail2Ban package. The host initially ran kernel 5.15.0-179 and booted into the already-installed 5.15.0-187 kernel during persistence testing. Automated project tests passed on the target; ShellCheck was unavailable on the VPS, while the same commit passed ShellCheck in local and GitHub CI runs.

## Verified workflows

### Platform and SSH

- Detected Ubuntu 22.04, APT, systemd, `ssh.service`, and the current SSH session on port 22.
- Preserved the default port while a temporary drop-in enabled both ports `22,32876`.
- Established a real new SSH connection through port 32876.
- Switched to a custom-only drop-in and confirmed that OpenSSH listened only on port 32876.
- Established another real SSH connection while only port 32876 was listening.
- Confirmed that SSH detection, firewall planning, Fail2Ban, and the doctor used only port 32876 and did not reintroduce port 22.
- Removed the temporary drop-in, restored the default port 22, and established a new port 22 connection.

### UFW

- Recorded SHA-256 hashes for both UFW user-rule files before testing.
- Applied, verified, and rolled back the default-port workflow without changing either rule file.
- Preserved every pre-existing IPv4 and IPv6 rule, including rules unrelated to this project.
- Added only `32876/tcp` when the temporary custom SSH port was enabled.
- Verified a real SSH connection through the new rule.
- Executed rollback from a real port 32876 session; the module returned its deferred-cleanup status and preserved the rule used by the current session.
- Switched back to port 22, reran rollback, and removed only the module-added `32876/tcp` rule.
- Confirmed that both final UFW rule-file hashes exactly matched their pre-test values.

### Fail2Ban

- Started with the Fail2Ban package absent and confirmed that read-only preflight stopped without changing the host.
- Installed Fail2Ban and its dependencies through the module's APT workflow.
- Applied and verified the systemd journal backend on port 22, both ports `22,32876`, and custom port 32876 only.
- Confirmed that the module-owned drop-in cleared inherited file-log paths when using the systemd backend.
- Observed the live `sshd` jail detect failed logins and ban hostile sources.
- Rolled the first installation workflow back to a disabled/inactive service with no module-owned configuration; installed packages were intentionally retained.
- Reapplied the final port 22 configuration and ended with Fail2Ban enabled and active.

### Reboot persistence

- Rebooted the VPS after restoring the final port 22 configuration.
- Confirmed that `ssh.service`, `ufw.service`, and `fail2ban.service` were enabled and active after boot.
- Confirmed that OpenSSH listened only on port 22 and that the Fail2Ban control socket and `sshd` jail were healthy.
- Confirmed that both UFW rule-file hashes still matched the pre-test baseline.
- Re-ran firewall verification, Fail2Ban verification, and `vps doctor`; the security checks passed.
- Observed a short post-boot SSH convergence period before new connections succeeded without intervention.

### Docker awareness

- Detected an existing Docker installation.
- Reported that published container ports require separate firewall review.
- Did not modify Docker, its networks, or its firewall rules.

## Final state

- OpenSSH listens on port 22 only.
- UFW is active and contains all original rules with no temporary integration-test rule.
- Fail2Ban is installed, enabled, active, and protects port 22 through the systemd backend.
- No temporary OpenSSH drop-in remains.
- `vps doctor` reports only the expected Docker firewall-awareness warning and no blocking issue.

## Remaining validation gaps

- a clean Ubuntu 22.04 installation with UFW initially inactive;
- `ssh.socket` activation;
- an explicitly selected file-log Fail2Ban backend using `/var/log/auth.log`;
- a custom-only port declared directly in the main `sshd_config`;
- APT/dpkg lock contention and interrupted-operation fault injection;
- Ubuntu 24.04.

Ubuntu 22.04 is therefore classified as compatible and manually validated for the workflows above, not fully supported under the complete compatibility policy.
