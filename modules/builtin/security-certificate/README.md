# Node Certificate Lifecycle

This module renews one already-enrolled `acme.sh` certificate, validates the
certificate/key pair, deploys it into an immutable generation directory, and
atomically switches a `current` symlink before reloading or restarting the
configured service. A failed issuance, deployment, service action, or required
health check leaves or restores the previous generation.

Before renewal, the module parses the configured `acme.sh` domain file as data,
requires its single `Le_Domain` value to match the configured hostname, and
refuses saved real-file deployment paths or pre/post/renew/reload/deploy hooks.
Those features can modify service state from inside `acme.sh`, before
the module can validate or roll back the result. A separate existing ACME cron
entry is also treated as a conflicting lifecycle owner.

The module requires an explicit root-owned configuration file at
`/etc/vps-secure/certificate-lifecycle.conf`. It does not discover domains,
private-key paths, listener ports, or protocol credentials automatically. See
`certificate-lifecycle.conf.example` for the supported keys.

The module accepts an exact DNS hostname, not a wildcard name, and verifies
that every staged certificate covers that hostname.

Scheduled execution performs the ACME client's normal per-domain renewal
check. It never adds `--force`. System cron entries contain the user field;
personal crontab entries do not. Protocol health checks are optional root-owned
executables whose output is suppressed; only their pass/fail state is reported.
Status distinguishes an installed cron entry from an observed natural renewal;
the former is not reported as evidence that the latter has occurred.

The service must read its certificate and key from:

```text
<deploy_root>/current/fullchain.pem
<deploy_root>/current/key.pem
```

For safety, `apply` requires `current` to already reference one valid managed
generation. Moving an existing service onto this managed path is a separate,
explicit onboarding change; the lifecycle transaction will not guess or
rewrite the service's current certificate configuration.

This module is independent from firewall ownership and repair. A successful
certificate transaction does not imply firewall or proxy-protocol health.
