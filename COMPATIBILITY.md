# Compatibility Policy

## Support levels

- **Supported**: included in automated tests and manually verified for high-risk workflows.
- **Compatible**: expected to work and covered by selected tests, but not every scenario is guaranteed.
- **Target**: planned for the 2.x line but not yet manually verified for high-risk workflows.
- **Experimental**: visible only with a warning; not included in one-click hardening promises.
- **Unsupported**: execution stops before system modification.

## Initial target matrix

| Platform | Level | Notes |
| --- | --- | --- |
| Debian 13 | Target | systemd journal-aware Fail2Ban configuration; manual validation pending |
| Debian 12 | Compatible | default, dual, and custom-only SSH ports; active and initially inactive UFW; journald Fail2Ban; reboot persistence; verification and rollback manually validated; remaining scenarios documented separately |
| Debian 11 | Target | security fixes only after capability detection; manual validation pending |
| Debian 10 | Unsupported target for 2.x | legacy script remains available; show lifecycle warning |
| Ubuntu 24.04 LTS | Target | test OpenSSH drop-ins and UFW |
| Ubuntu 22.04 LTS | Compatible | default, dual, and custom-only SSH ports; complex existing UFW rules; Fail2Ban installation, journal backend, rollback, active-session protection, and reboot persistence manually validated |
| Rocky/AlmaLinux | Experimental | excluded from initial modular hardening release |

## Mandatory scenarios

High-risk modules are not marked supported until these scenarios pass where applicable:

- default SSH port;
- custom SSH port in the main configuration;
- custom SSH port in `sshd_config.d`;
- multiple SSH ports;
- systemd SSH socket activation;
- missing `/var/log/auth.log`;
- Fail2Ban journal backend;
- existing UFW or nftables rules;
- Docker already installed;
- existing Swap;
- kernel without BBR support;
- repeated execution;
- APT/dpkg lock contention;
- interrupted download;
- failed service validation and rollback.

## Definition of support

Recognizing `/etc/os-release` is not sufficient. A supported platform must have tested adapters, safe failure behavior, post-change verification, and documented recovery steps.

Current manual validation records are available for [Debian 12](docs/DEBIAN_12_VALIDATION.md) and [Ubuntu 22.04](docs/UBUNTU_22_04_VALIDATION.md).
