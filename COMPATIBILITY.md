# Compatibility Policy

## Support levels

- **Supported**: included in automated tests and manually verified for high-risk workflows.
- **Compatible**: expected to work and covered by selected tests, but not every scenario is guaranteed.
- **Experimental**: visible only with a warning; not included in one-click hardening promises.
- **Unsupported**: execution stops before system modification.

## Initial target matrix

| Platform | Level | Notes |
| --- | --- | --- |
| Debian 13 | Supported target | systemd journal-aware Fail2Ban configuration |
| Debian 12 | Supported target | test with and without `/var/log/auth.log` and rsyslog |
| Debian 11 | Compatible target | security fixes only after capability detection |
| Debian 10 | Unsupported target for 2.x | legacy script remains available; show lifecycle warning |
| Ubuntu 24.04 LTS | Supported target | test OpenSSH drop-ins and UFW |
| Ubuntu 22.04 LTS | Supported target | test OpenSSH drop-ins and UFW |
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
