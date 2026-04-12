# Security model

Archarden is designed around a deliberately small public surface.

## Publicly exposed

- `443/tcp` via Nginx Proxy Manager
- WireGuard UDP (default `51820/udp`)

## Private admin plane

- NPM admin: WireGuard-only
- Uptime Kuma: WireGuard-only
- SSH after lockdown: WireGuard-only

## ntfy

ntfy is the only intended public-facing service. Archarden generates a private-by-default configuration:

- `auth-default-access: deny-all`
- `web-root: disable`
- `require-login: true`
- generated admin account
- generated publisher user and write-only publisher token
- no anonymous wildcard read ACL

## Host hardening

Archarden also disables LLMNR and MulticastDNS under `systemd-resolved`, keeps SELinux enforcing, and verifies that no unexpected public listeners remain.
