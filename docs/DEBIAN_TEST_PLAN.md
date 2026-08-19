# Debian Integration Test Plan

## Safety boundary

Run destructive integration tests only on disposable VPS instances with provider console access and a snapshot. Do not begin on a production server. Keep the original SSH session open during firewall tests.

## Target images

- Debian 12 minimal without rsyslog
- Debian 12 with rsyslog and `/var/log/auth.log`
- Debian 13 minimal
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS

## SSH scenarios

1. Default port 22 in the main configuration.
2. Custom port in `/etc/ssh/sshd_config`.
3. Custom port in `/etc/ssh/sshd_config.d/*.conf`.
4. Multiple configured ports.
5. Active `ssh.socket` where available.
6. A current session port that conflicts with parsed configuration.

For every scenario, `vps ssh status`, `vps firewall plan`, and `vps fail2ban plan` must include the current connection port. If no reliable port can be found, firewall apply must stop before enabling UFW.

## Firewall lifecycle

1. Record provider firewall and console access.
2. Run `vps firewall plan` as an unprivileged user.
3. Run `sudo vps firewall apply` while keeping the current SSH session open.
4. Open a second SSH connection on the existing custom port.
5. Verify no implicit 22, 80, or 443 rule was added.
6. Run apply a second time and confirm idempotency.
7. Run rollback and confirm only rules added by the latest transaction are removed.
8. Test both initially inactive and initially active UFW states.

## Fail2Ban lifecycle

1. Confirm which log backend the plan selects.
2. Apply and run `vps fail2ban verify`.
3. Confirm the `sshd` jail contains every active SSH port.
4. Confirm `/etc/fail2ban/jail.local` is unchanged.
5. Introduce an invalid candidate in a disposable test and verify restoration.
6. Run rollback and compare the module configuration with its pre-apply state.

## Evidence to retain

- command output and exit status;
- `/etc/os-release`;
- `sshd -T` port output;
- active listeners from `ss`;
- UFW status before and after;
- Fail2Ban configuration test and jail status;
- module transaction directory contents;
- successful second SSH connection.
