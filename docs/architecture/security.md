# Security Model

## Intended exposure model

Public internet:

- `443/tcp`
- `51820/udp`

Private/VPN-only:

- NPM admin
- Uptime Kuma
- post-lockdown SSH
- any other explicitly VPN-gated admin surface

Loopback/internal:

- rootless service backends and supporting ports

## Security goals

- remove public admin panels
- reduce scan noise and brute-force opportunities
- centralize public ingress at the reverse proxy
- treat the VPN as the administrative trust boundary
- keep service bindings explicit

## What this does and does not mean

This is not a claim of permanent security or formal assurance. It is a claim about exposure and clarity.

Archarden tries to make the trust boundaries obvious:

- public traffic terminates at the reverse proxy
- administrative access lives on the VPN plane
- service backends stay local unless explicitly surfaced

That is a more useful operational goal than vague hardening language, because it answers the practical question that actually matters: what is reachable, from where, and why?

## Security lessons from the build

- If secrets are passed inline in process args, they leak into `ps`.
- If socket proxies are misconfigured, a service can look healthy while the exposure path is dead.
- If WireGuard routing is wrong, every higher-level assumption falls apart.
- Public-facing HTTPS remains the primary concentration of public risk.

## Why publish these edges

Because most beginner-friendly hardening advice stops too early. Installing a firewall or fail2ban is not useless; it is simply not the whole picture. The harder and more valuable question is how ingress, service ownership, routing, and administrative trust boundaries fit together.

That is the part this project tries to make visible.
