# Architecture Overview

Archarden is best understood as four interacting layers:

1. **Host hardening layer**
2. **Admin-plane networking layer**
3. **Service orchestration layer**
4. **Operational tooling layer**

## Layer 1: host hardening

SSH, firewall, journald, sysctl, tmpfs `/tmp`, fail2ban, package state.

## Layer 2: admin plane

WireGuard on `wg0`, with administrative interfaces intentionally pushed off the public network.

## Layer 3: service orchestration

Rootless Podman services under `podmin`, plus root-owned systemd and socket constructs where privileged or VPN-only exposure is needed.

## Layer 4: operations

Verification, diagnostics, backups, exports, notifications, and lockdown.

## Why the layering matters

The interesting part of Archarden is not that Bash installs packages. Plenty of scripts can do that. The interesting part is how these layers interact:

- a service can be healthy while its exposure path is broken
- a VPN can be up while the advertised route is wrong
- a container can be reachable on loopback and still be inaccessible where the operator expects it
- a systemd unit can look reasonable and still be wired incorrectly

That is exactly why this project is worth publishing in its imperfect form. It shows where Linux systems stop being components and start being interactions.
