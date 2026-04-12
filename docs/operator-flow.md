# Operator flow

1. Run `archarden apply` on a fresh Arch host.
2. Reconnect after any required reboot.
3. Run `archarden doctor` and `archarden verify`.
4. Import the generated WireGuard client config and connect.
5. Access NPM admin over WireGuard and create the `ntfy` proxy host.
6. Request the SSL certificate for `ntfy.<domain>` in NPM using Cloudflare DNS challenge.
7. Run `archarden lockdown` to move SSH to the WireGuard-only posture.
8. Validate ntfy and Uptime Kuma.
