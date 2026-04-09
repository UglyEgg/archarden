# Operator Flow

## Recommended flow

1. Review config and docs.
2. Run `apply --dry-run`.
3. Run `apply` for real.
4. Wait for phase 1 completion and reboot.
5. Run `verify` and `doctor`.
6. Export and import WireGuard client config.
7. Access NPM/Kuma/ntfy over VPN.
8. Rotate credentials with `creds`.
9. Initialize notifications.
10. Test recovery paths.
11. Run `lockdown` only after VPN-admin access is proven.

## Why this order

This order intentionally avoids the classic self-own: enabling restrictive access controls before confirming the admin plane actually works.
