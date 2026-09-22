# Verified SSH login hardening

This module prepares a non-root sudo user, imports a public key through the
existing SSH key transaction, and requires proof from a separate public-key
SSH session before it can disable password authentication. Root login is a
separate final step and requires another verification after passwords have
been disabled.

The module owns only `00-vps-secure-login-hardening.conf`. It validates the
effective OpenSSH configuration, reloads the service, verifies the resulting
policy and restores the previous file if any step fails. It never changes the
SSH port.
