# Module Specification

## 1. Purpose

This document defines the minimum contract between the VPS Secure core and a feature module. A module may remain independently executable, but platform integration must use this contract rather than menu-specific coupling.

## 2. Required files

```text
module-directory/
├── module.conf
├── module.sh
├── README.md
└── tests/
```

`module.conf` is data, not executable shell code. The core parses only known keys and must never `source` a downloaded manifest.

Example:

```ini
id=monitoring.latency
name=Latency and packet-loss monitoring
version=1.0.0
category=monitoring
entry=module.sh
trust=official
privilege=unprivileged
background_service=true
supported_platforms=debian:12+,debian:13+,ubuntu:22.04+
dependencies=ping,systemd
actions=check,plan,configure,start,stop,status,verify
```

## 3. Required actions

Modules implement applicable actions through their entry point:

```text
module.sh check
module.sh plan
module.sh preflight
module.sh apply
module.sh verify
module.sh status
module.sh backup
module.sh rollback
module.sh configure
module.sh start
module.sh stop
module.sh uninstall
module.sh doctor
```

Minimum requirements by module type:

- Read-only module: `check`, `status`, `doctor`
- Monitoring module: `check`, `apply`, `verify`, `status`, `configure`, `start`, `stop`, `uninstall`
- System-changing module: `check`, `plan`, `preflight`, `backup`, `apply`, `verify`, `rollback`, `status`

`preflight` validates a generated candidate against a temporary copy of the effective configuration. It must not write system configuration, start or restart services, or otherwise change the target system.

## 4. Exit status

```text
0   completed successfully
10  safely skipped; desired state already exists
20  platform or capability is unsupported
30  preflight check failed
40  apply failed
50  verification failed
60  rollback failed
64  invalid arguments or module contract violation
```

Human-readable output goes to standard output. Diagnostic details go to standard error. Modules must not depend on parsing colored menu text.

## 5. Privilege levels

```text
unprivileged   no system modification
data-write     writes only module-owned state
system         changes system packages or configuration
high-risk      may affect remote access, firewall, services, or user data
external-root  executes separately maintained code with root privileges
```

The core performs confirmation and backup policy based on the declared level. A module may not silently elevate beyond its declaration.

## 6. Configuration ownership

A module writes only files with a project-specific name, for example:

```text
/etc/ssh/sshd_config.d/90-vps-secure.conf
/etc/fail2ban/jail.d/90-vps-secure.local
/etc/sysctl.d/90-vps-secure.conf
```

Primary system files such as `/etc/ssh/sshd_config`, `/etc/fail2ban/jail.local`, and `/etc/sysctl.conf` are treated as user or distribution owned.

## 7. Installation from a URL

The module registry records an immutable release URL, semantic version, SHA-256 digest, supported platforms, entry point, privilege declaration, and source repository.

Installation sequence:

1. download to a temporary directory;
2. require a successful HTTP response;
3. verify size and SHA-256;
4. validate manifest keys and module ID;
5. run contract and syntax checks;
6. install through a temporary directory and atomically replace the active module;
7. retain transaction metadata and a copy of the previous module for recovery.

The platform does not execute the contents of a mutable remote branch directly as root.

## 8. Compatibility wrappers

An existing standalone script may be integrated through a wrapper module. The wrapper translates module actions to the legacy script without requiring an immediate rewrite. Interactive prompts must remain separate from domain logic so command and menu modes behave consistently.

For curated external tools, the wrapper records an immutable entry URL, upstream commit, license, and SHA-256. Verification covers the downloaded entry file only. If that file downloads other scripts or binaries, the plan and user interface must disclose the additional trust boundary before execution.

The beginner interface presents task-specific wording and may intentionally expose only a subset of module actions. `plan`, `verify`, and `check` remain part of the module contract even when a guided workflow invokes them automatically instead of listing them as separate menu items.
