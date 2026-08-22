# Debian 13 Validation Record

## Scope

This record summarizes a manual integration run completed on 2026-08-22 with the
published `2.0.0-beta.4` release. Host, client, and hostile-source addresses are
intentionally omitted.

The target was a fresh minimal Debian 13 installation using systemd,
`ssh.service`, OpenSSH on port 22, UFW, and Fail2Ban with the systemd journal
backend. The host started on a 6.12.38 kernel and booted into the installed
6.12.101 kernel during the persistence test.

The minimal image did not include curl. The original copied installation block
therefore failed at its first download and continued into misleading checksum,
extraction, and installation errors. After `ca-certificates` and `curl` were
installed through APT, the published archive installation completed and the
global `vps` command opened normally. This exposed an installation-documentation
gap rather than a Debian 13 runtime incompatibility.

The provider image also had a hostname that did not match `/etc/hosts`, causing
sudo to print an `unable to resolve host` warning. Correcting the local hostname
mapping removed the warning. The warning did not cause the release download
failure.

## Verified workflows

### Platform and SSH

- Detected Debian 13, APT, systemd, `ssh.service`, and the current port 22 SSH
  session.
- Confirmed that the doctor, SSH status, firewall plan, and Fail2Ban plan retained
  the existing SSH port without falling back to 22 as an invented default.
- Added a temporary OpenSSH drop-in selecting port 32876 and confirmed that the
  platform detected the transition ports before restarting SSH.
- Applied the firewall before restarting SSH, confirmed that OpenSSH listened on
  port 32876, and established a real new external SSH connection through that
  port.
- Removed the temporary drop-in, restarted SSH, restored the Termius host to port
  22, and established a real new port 22 connection.

### UFW

- Confirmed an active firewall with only the expected port 22 IPv4 and IPv6
  rules.
- Repeated a healthy apply and confirmed that it did not duplicate rules or
  replace the existing meaningful rollback point.
- Rolled the module back to the pre-application inactive state.
- Reapplied the module and confirmed that it added only the confirmed SSH port
  before enabling UFW.
- Added port 32876 during the live SSH transition, verified it from the new
  external session, then rolled back only that temporary rule after returning to
  port 22.

### Fail2Ban

- Confirmed that the installed service responded to `fail2ban-client ping` and
  that the live sshd jail was detecting failed logins and banning hostile
  sources.
- Repeated a healthy apply without restarting the service or replacing the
  meaningful rollback point.
- Rolled back the module-owned configuration while retaining the package-managed
  enabled and active service state.
- Ran the non-mutating merged-configuration preflight successfully.
- Reapplied and verified the systemd journal backend on port 22 and during the
  `22,32876` transition, then restored the final port 22 configuration.
- Confirmed that `/etc/fail2ban/jail.local` was absent and that the platform used
  only `/etc/fail2ban/jail.d/90-vps-secure.local`.

### Reboot persistence

- Confirmed before reboot that SSH, UFW, and Fail2Ban were enabled.
- Rebooted the VPS and established a fresh Termius connection on port 22.
- Confirmed that `ssh.service`, `ufw.service`, and `fail2ban.service` were active
  after boot.
- Confirmed that UFW retained only the expected port 22 rules and that Fail2Ban
  responded to its client.
- Re-ran firewall verification, Fail2Ban verification, and `vps doctor`; all
  passed.

## Final state

- OpenSSH listens on port 22 and accepts new external sessions.
- UFW is enabled and active with only the expected port 22 IPv4 and IPv6 rules.
- Fail2Ban is enabled, active, and protects port 22 through the systemd backend.
- No temporary OpenSSH drop-in or port 32876 firewall rule remains in active
  configuration.
- The global `vps` command is installed and the doctor reports no blocking issue.

## Remaining validation gaps

- a custom port placed directly in the main `sshd_config` rather than a drop-in;
- systemd SSH socket activation, which is covered by the Ubuntu 24.04 record;
- an explicitly selected file-log Fail2Ban backend;
- APT/dpkg lock contention and interrupted-operation fault injection;
- hosts with complex pre-existing UFW or nftables policy.

Debian 13 is therefore classified as compatible and manually validated for the
workflows above, not fully supported under the complete compatibility policy.
