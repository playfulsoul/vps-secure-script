# Beszel central monitoring agent

This built-in module enrolls one Debian or Ubuntu VPS into an existing Beszel
Hub. It installs a versioned upstream binary only after verifying the checksum
published with the same immutable Beszel release.

Security boundaries:

- the agent initiates an outbound WebSocket connection to a stable HTTPS Hub
  hostname;
- the embedded SSH listener is disabled, so the module does not open an
  inbound port or change the firewall;
- the Hub token and public key are read from protected files, never accepted
  as command-line values, and are stored in mode `0600` files;
- the agent's credential and data directories are outside the platform's
  root-only `/etc/vps-secure` and `/var/lib/vps-secure` trees, so the unprivileged
  service can traverse only its dedicated paths;
- the service is not added to the `docker` or `disk` groups;
- local service health is not reported as proof that the Hub received data;
- `uninstall` removes module-owned active credentials but preserves the agent
  fingerprint data and a protected rollback transaction.

Examples:

```bash
sudo vps monitor join \
  --hub-url https://monitor.example.com \
  --key-file /root/beszel-public-key \
  --token-file /root/beszel-token \
  --yes

vps monitor status

sudo vps monitor rebind --hub-url https://new-monitor.example.com --yes
sudo vps monitor leave --yes
```

For an interactive manual enrollment, run `sudo vps monitor join-prompt` in
the **target VPS's SSH session**. It asks for the Hub HTTPS address, that
system's public key, and that system's token. The key and token prompts do not
echo input; the values are passed to `join` through temporary mode `0600`
files and never appear in the shell command or process arguments. Do not paste
either value at an ordinary shell prompt on your computer. After installation,
check the system's latest sample in the Hub; a running local service alone is
not proof of enrollment.

The source credential files must be regular, non-symlink files with no group or
other permissions. A Hub migration that preserves both the stable hostname and
the complete Hub data should not require `rebind`.
