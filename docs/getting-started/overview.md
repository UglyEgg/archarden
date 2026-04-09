# Overview

Archarden turns a fresh Arch Linux VPS into a VPN-gated host with a reverse-proxied service edge and a deliberately minimized public surface.

## Core objectives

- Expose as little as possible publicly.
- Make privileged and administrative interfaces reachable only over WireGuard.
- Prefer explicit, inspectable host mutations over invisible magic.
- Preserve enough state to resume after required reboots.
- Keep the result understandable by another operator reading the repo later.

## Primary components

- **Host hardening**: SSH restrictions, fail2ban, firewall defaults, sysctl tuning, journald, `/tmp` tmpfs.
- **Admin plane**: WireGuard on `wg0`, optional post-lockdown SSH only on `wg0`.
- **Ingress**: Nginx Proxy Manager as the public HTTPS edge.
- **Services**: Rootless Podman-managed NPM, ntfy, and Uptime Kuma under `podmin`.
- **Operational helpers**: `verify`, `doctor`, `wg export`, backups, notifications, resume state.

## How to read the project

There are easier ways to solve this class of problem. That is not a secret and not a defect in the documentation.

Archarden is useful because it keeps the underlying system visible. Tools like Ansible or Terraform are valuable partly because they abstract service management, networking, and convergence details. Archarden does much less of that. The tradeoff is more manual complexity in exchange for a clearer view of what those layers are actually doing.

That makes it a reasonable working project and a useful teaching artifact, especially for people who want to understand where the abstraction boundaries are instead of starting there.

## Scope discipline

Archarden is intentionally **single-host** and **opinionated**. Once the project started growing, the right move was to draw boundaries instead of pretending it was a universal provisioning system.
