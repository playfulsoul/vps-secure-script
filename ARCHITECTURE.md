# VPS 管理与安全平台 Architecture

## 1. Product direction

VPS 管理与安全平台（原 VPS Secure Platform）is an integrated VPS security, operations, application, monitoring, and diagnostics platform. The `vps` command provides one consistent user experience while individual capabilities are delivered by independently testable modules.

The repository name, command, environment variables, and `/usr`, `/etc`, and `/var` paths retain their existing `vps-secure` identifiers as compatibility contracts. Product display naming is intentionally decoupled from these internal identifiers.

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
- Task-oriented beginner menus expose concrete outcomes and feature keywords; technical lifecycle actions stay in advanced and command modes.
- Advanced module menu: available from the beginner dashboard
- Command mode: `vps <module> <action>`
- Diagnostics: `vps doctor`
- Release checks and verified self-update: `vps update <check|apply|rollback>`
- Module management: `vps module <list|info|install|update>`; module-specific actions are declared in each `module.conf`. There is no generic module disable/uninstall command.

### Core

The core is responsible for:

- module discovery and routing;
- platform and capability detection;
- privilege and risk confirmation;
- state paths and transaction pointers;
- installation/update locks and recovery; individual modules own their configuration backups and rollback behavior;
- module download, version, and integrity verification.

The core must not contain Docker, Fail2Ban, latency-monitoring, or other domain-specific implementation details.

### Platform adapters

Current helpers and modules handle:

- Debian and Ubuntu release detection;
- APT-based package operations and module-specific package checks;
- systemd service management;
- OpenSSH effective configuration and socket activation;
- UFW runtime rules and competing firewall persistence services;
- journal and file-based logging backends.

### Modules

Initial module categories:

- `security`: SSH public keys, firewall, Fail2Ban;
- `system`: packages, users, Swap, BBR, status;
- `applications`: Docker, 1Panel, loopback-only remote desktop;
- `monitoring`: latency, packet loss, interface traffic;
- `diagnostics`: route tracing, benchmark and IP-quality tools.

## 4. Trust model

### Built-in modules

Security-critical modules shipped and tested with the core. They may use shared internal libraries.

### Official extension modules

Maintained by the project but versioned independently. They are downloaded to a temporary location, verified, and installed locally before execution.

### Third-party modules

Untrusted by default. They run as separate processes, declare required privileges and changes, and are never sourced into the core shell process.

The built-in diagnostics catalog pins each selected entry script to an immutable upstream commit and SHA-256. Some third-party entry scripts download additional components at runtime; the interface must disclose that downstream trust boundary and must not describe entry-file verification as a full audit.

## 5. Filesystem layout

Development layout:

```text
.github/                 CI, issue forms and pull-request templates
bin/                     command entry points
core/                    routing, state, logging, backup and adapters
modules/builtin/         security-critical first-party modules
modules/official/        optional first-party modules during development
registry/                module catalog and integrity metadata
tests/unit/              deterministic unit tests
tests/integration/       distribution and service integration tests
docs/                    user, testing and maintainer documentation
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

The platform combines confirmed ports from these sources, including the current connection port. It stops before enabling a firewall if no port can be reliably confirmed. Port 22 is never used as a fallback merely because configuration parsing failed.

The basic SSH module imports public keys; it does not change SSH ports or disable password login. The separate high-risk login-hardening module can prepare an ordinary sudo user and change password/root policy only after a matching public-key session is proven in a new window. Password removal and root restriction are two distinct gates, each followed or preceded by a fresh-session check. The module owns one SSH drop-in, verifies effective daemon values after reload, and never writes a `Port` directive.

Firewall rollback retains a newly added rule when it protects the current SSH session and asks the user to switch to another allowed port before retrying.

## 7. Monitoring direction

The built-in collector measures latency, packet loss and interface traffic. Third-party bandwidth tests are separate, explicit operations and can consume substantial traffic.

The current Bash-based 2.x line uses systemd timers for lightweight local collection. High-volume tests and centralized monitoring are outside the built-in collector's current contract.

## 8. Release strategy

- `1.0.1` remains the immutable legacy baseline.
- The historical raw `vps_secure.sh` URL serves a standalone migration assistant. It installs a verified complete 2.x bundle instead of attempting a cross-architecture single-file update.
- `2.x` introduces the modular Bash platform and compatibility fixes.
- Releases use a verified full bundle, and installed platforms retrieve updates through the same integrity-checked lifecycle.
- Remote module execution via `curl | bash` is not part of the trusted module lifecycle.
