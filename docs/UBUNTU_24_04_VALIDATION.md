# Ubuntu 24.04 Validation Record

## Scope

This record summarizes a manual integration run completed across 2026-08-20 and 2026-08-21. Testing began on commit `4eec464f9b5f6ecfc8d4f3f3a2ef231e6e4a8d42`; defects found during the run were fixed and the final workflows passed on commit `8e55f1e`. Host, client, and hostile-source addresses are intentionally omitted.

The target was a fresh Ubuntu 24.04 installation with kernel 6.8, default systemd `ssh.socket` activation, an installed but initially inactive UFW with no user rules, rsyslog and `/var/log/auth.log`, and no Fail2Ban or Docker package. Automated project tests passed on the target. ShellCheck was unavailable on the VPS, while the tested code passed ShellCheck locally and in GitHub CI.

## Verified workflows

### Platform and socket-activated SSH

- Detected Ubuntu 24.04, APT, systemd, the active `ssh.socket`, and the current SSH session on port 22.
- Confirmed that Ubuntu's systemd generator translated an OpenSSH drop-in containing `Port 22` and `Port 32876` into a dual-listener `ssh.socket` configuration.
- Established a real new SSH connection through port 32876.
- Changed the OpenSSH drop-in to port 32876 only, reloaded systemd, and confirmed that both the socket and daemon stopped listening on port 22.
- Established another real SSH connection while only port 32876 was listening.
- Confirmed that the doctor, SSH status, firewall, and Fail2Ban used only port 32876 and did not reintroduce port 22.
- Rebooted in the custom-only state and successfully reconnected through port 32876 after boot.
- Removed the temporary drop-in, regenerated the default socket configuration, and established a new port 22 connection.

### UFW

- Started with UFW inactive and no user rules.
- Applied the module and confirmed that it added only `22/tcp` before enabling UFW.
- Verified that a repeated apply did not duplicate the rule.
- Found that a no-change repeated apply replaced the meaningful rollback pointer in the original implementation.
- Fixed repeated apply to avoid redundant enable operations and preserve the previous meaningful rollback point.
- Verified the fix with automated coverage and a real `apply -> repeated apply -> rollback` workflow; rollback restored UFW to inactive with no user rules.
- Reapplied the final active firewall state, added only `32876/tcp` for the temporary custom port, and established a real connection through it.
- Executed rollback from a real port 32876 session and confirmed that the module deferred cleanup while retaining the current session rule.
- Switched back to port 22, reran rollback, and removed only the temporary 32876 rule.

UFW rewrote its internal rule files during enable/disable operations, so their byte hashes changed even after the semantic state returned to inactive with no user rules. The project did not directly overwrite those internal files.

### Fail2Ban

- Started with the Fail2Ban package absent and confirmed that read-only preflight stopped without changing the host.
- Installed Ubuntu's Fail2Ban 1.0.2 package and dependencies through the module's APT workflow.
- Applied and verified the systemd journal backend on port 22, both ports `22,32876`, and custom port 32876 only.
- Found the same rollback-pointer risk for a healthy repeated Fail2Ban apply and fixed it before repeated live application.
- Verified that repeated apply retained the meaningful transaction, kept the same service process, and did not restart or re-enable the healthy service.
- Verified rollback removal of the module-owned configuration. The installed package and its package-managed enabled/active service state were intentionally retained.
- Observed the live `sshd` jail detect failed logins and ban hostile sources.
- Reapplied the final port 22 configuration and ended with Fail2Ban enabled and active.

### Reboot persistence

- Rebooted while OpenSSH listened only on custom port 32876.
- Confirmed after boot that `ssh.socket`, `ssh.service`, `ufw.service`, and `fail2ban.service` were active and that the required units were enabled.
- Confirmed that only port 32876 listened, UFW allowed it, and Fail2Ban protected it.
- Re-ran firewall verification, Fail2Ban verification, and `vps doctor`; all passed.

### Build and system installation

- Built the `2.0.0-dev` release archive and verified its generated SHA-256 checksum.
- Installed the platform into `/usr/lib/vps-secure` with the `/usr/local/bin/vps` command link.
- Verified the global version command, complete built-in module registry, doctor, firewall verification, and Fail2Ban verification.

## Defects discovered during the run

1. A repeated no-change firewall apply replaced the earlier meaningful rollback point.
2. A repeated healthy Fail2Ban apply would restart the service and replace the earlier meaningful rollback point.

Both defects were fixed in the development branch, received functional regression coverage, passed local ShellCheck and all test suites, and were verified on the target VPS.

## Final state

- `ssh.socket` is enabled and active, and OpenSSH listens on port 22 only.
- UFW is enabled and active with only the expected port 22 SSH rule.
- Fail2Ban is installed, enabled, active, and protects port 22 through the systemd backend.
- No temporary OpenSSH drop-in or port 32876 firewall rule remains.
- The global `vps` command is installed and verified.
- `vps doctor` reports no blocking issue or warning.

## Remaining validation gaps

- an explicitly selected file-log Fail2Ban backend using `/var/log/auth.log`;
- APT/dpkg lock contention and interrupted-operation fault injection;
- Debian 11 and Debian 13;
- Ubuntu 26.04.

Ubuntu 24.04 is therefore classified as compatible and manually validated for the workflows above, not fully supported under the complete compatibility policy.
