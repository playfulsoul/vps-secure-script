# Module Specification

## 1. Purpose

This document defines the minimum contract between the VPS Secure core and a feature module. A module may remain independently executable, but platform integration must use this contract rather than menu-specific coupling.

## 2. Module files

```text
module-directory/
├── module.conf
├── module.sh
├── README.md
└── tests/
```

`module.conf` is data, not executable shell code. The core parses only known keys and must never `source` a downloaded manifest.

The runtime requires a valid manifest and its declared entry file. README and tests are documentation and maintenance conventions, not installer-enforced files.

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

## 3. Recognized actions

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

These are recognized action names, not actions implemented by every module. The manifest's `actions` field is authoritative; the dispatcher rejects undeclared actions. For example, the network module declares collection/timer actions but no uninstall, and SSH uses configure for public-key import. Inspect `vps module info <id>` before invoking a module action.

`preflight` validates a generated candidate against a temporary copy of the effective configuration. It must not write system configuration, start or restart services, or otherwise change the target system.

## 4. Exit status

```text
0   completed successfully
10  safely skipped; desired state already exists
20  platform or capability is unsupported
30  preflight check failed
40  apply failed
50  verification failed
60  rollback or automatic compensation incomplete/failed
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

The core enforces confirmation for mutating actions and checks declared privilege. Backups and recovery are implemented by the individual module, not automatically supplied to every module by the dispatcher. A module may not silently elevate beyond its declaration.

## 6. Configuration ownership

A module writes only files with a project-specific name, for example:

```text
/etc/ssh/sshd_config.d/90-vps-secure.conf
/etc/ssh/sshd_config.d/00-vps-secure-login-hardening.conf
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
5. validate the manifest and the declared entry path;
6. install through a temporary directory and atomically replace the active module;
7. retain transaction metadata and a copy of the previous module for recovery.

The platform does not execute the contents of a mutable remote branch directly as root.

## 8. Compatibility wrappers

An existing standalone script may be integrated through a wrapper module. The wrapper translates module actions to the legacy script without requiring an immediate rewrite. Interactive prompts must remain separate from domain logic so command and menu modes behave consistently.

For curated external tools, the wrapper records an immutable entry URL, upstream commit, license, and SHA-256. Verification covers the downloaded entry file only. If that file downloads other scripts or binaries, the plan and user interface must disclose the additional trust boundary before execution.

The beginner interface presents task-specific wording and may intentionally expose only a subset of declared module actions. Guided workflows invoke applicable checks directly.

## 9. Firewall and Fail2Ban recovery results

These modules serialize mutating operations with a module lock. Before the first managed configuration change they save a pending transaction with recovery evidence. Application failure returns 40 (or 50 for verification) even if automatic compensation succeeds. Incomplete compensation returns 60, retains the pending transaction, and blocks another apply/configure until recovery is resolved. Explicit rollback can retry a pending recovery; a completed rollback is not applied a second time.

TERM/INT/HUP trigger a module recovery attempt. SIGKILL or power loss cannot run a shell trap: inspect the saved evidence and process state before manually recovering a stale operation lock. Package installation is not undone. Firewall persistence recovery restores recorded service enablement, not the complete previous runtime packet-filter table; it reports this limitation. A current-session SSH rule may be retained, in which case rollback is incomplete and can be retried after switching sessions. The lock serializes platform operations, not external administrators; do not edit managed settings concurrently with apply or recovery.
