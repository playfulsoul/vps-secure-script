# VPS Secure Platform Architecture

## 1. Product direction

VPS Secure Platform is an integrated VPS security, operations, application, monitoring, and diagnostics platform. The `vps` command provides one consistent user experience while individual capabilities are delivered by independently testable modules.

The project is not intended to become a single ever-growing shell file. The core owns platform behavior; modules own domain behavior.

## 2. Design principles

1. Preserve access before hardening. Initialization must never change an existing SSH port implicitly.
2. Detect capabilities instead of assuming distribution defaults.
3. Every system change follows `check -> plan -> apply -> verify`; high-risk changes also support `backup -> rollback`.
4. A failed verification is a failed operation. Success messages must be backed by evidence.
5. The platform only edits configuration files it owns. It must not overwrite user-managed primary configuration files.
6. Remote URLs are discovery and download sources, not root execution entry points.
7. Built-in, official, and third-party modules have different trust levels.
8. Interactive menus and command-line automation call the same module operations.

## 3. Layers

### User interfaces

- Beginner dashboard and guided workflows: `vps`
- Advanced module menu: available from the beginner dashboard
- Command mode: `vps <module> <action>`
- Diagnostics: `vps doctor`
- Release checks and verified self-update: `vps update <check|apply|rollback>`
- Module management: `vps module <list|info|install|update|disable|uninstall>`

### Core

The core is responsible for:

- module discovery and routing;
- platform and capability detection;
- privilege and risk confirmation;
- structured logging;
- configuration, state, and lock management;
- backup and rollback orchestration;
- task scheduling and background-service integration;
- module download, version, and integrity verification.

The core must not contain Docker, Fail2Ban, latency-monitoring, or other domain-specific implementation details.

### Platform adapters

Adapters normalize operating-system differences:

- Debian and Ubuntu release detection;
- APT and dpkg locking;
- systemd service management;
- OpenSSH effective configuration and socket activation;
- UFW, nftables, and Docker firewall interaction;
- journal and file-based logging backends.

### Modules

Initial module categories:

- `security`: SSH, firewall, Fail2Ban, security audit;
- `system`: packages, users, Swap, BBR, status;
- `applications`: Docker, 1Panel;
- `monitoring`: latency, packet loss, traffic, TCP/HTTP availability;
- `diagnostics`: route tracing, benchmark and IP-quality tools.

## 4. Trust model

### Built-in modules

Security-critical modules shipped and tested with the core. They may use shared internal libraries.

### Official extension modules

Maintained by the project but versioned independently. They are downloaded to a temporary location, verified, and installed locally before execution.

### Third-party modules

Untrusted by default. They run as separate processes, declare required privileges and changes, and are never sourced into the core shell process.

## 5. Filesystem layout

Development layout:

```text
bin/                     command entry points
core/                    routing, state, logging, backup and adapters
modules/builtin/         security-critical first-party modules
modules/official/        optional first-party modules during development
registry/                module catalog and integrity metadata
tests/unit/              deterministic unit tests
tests/integration/       distribution and service integration tests
docs/                    user and maintainer documentation
legacy/v1.0.1/           immutable legacy baseline
```

Installed layout:

```text
/etc/vps-secure/                  user configuration
/var/lib/vps-secure/              state and monitoring data
/var/lib/vps-secure/backups/      timestamped backups
/var/log/vps-secure/              operation logs
/usr/lib/vps-secure/              core and built-in modules
/usr/local/lib/vps-secure/        optional and user-installed modules
/usr/local/bin/vps                command entry point
```

## 6. SSH access invariant

Security initialization must preserve every confirmed SSH listening port. Port discovery uses multiple evidence sources:

1. the server port of the current SSH connection;
2. active listening sockets owned by OpenSSH or `ssh.socket`;
3. effective `sshd -T` output;
4. systemd socket configuration where applicable.

If these sources conflict, the platform preserves the current connection port and stops before enabling a firewall until the conflict is resolved. Port 22 is never used as a fallback merely because configuration parsing failed.

Changing an SSH port is a separate, explicit workflow. The old port remains allowed until the user verifies a new connection.

## 7. Monitoring direction

Lightweight continuous collectors may measure latency, packet loss, TCP/HTTP response time, resource use, and interface traffic. Bandwidth speed tests are active, traffic-consuming jobs and remain opt-in with frequency and traffic limits.

The Bash-based 2.x line establishes module boundaries. A later daemon may be implemented as a small compiled service if continuous collection, concurrency, retention, and alerting exceed what shell and systemd timers can safely provide.

## 8. Release strategy

- `1.0.1` remains the immutable legacy baseline.
- `2.x` introduces the modular Bash platform and compatibility fixes.
- A thin installer may download the core and selected modules.
- A verified full bundle may be offered for offline or rescue use.
- Remote module execution via `curl | bash` is not part of the trusted module lifecycle.
