# Lockdown

Lockdown is the stage where Archarden tightens ingress further, typically moving SSH to a WireGuard-only binding and expecting VPN-based administration to be the norm.

## Before running lockdown

Confirm all of the following:

- WireGuard handshakes from your workstation
- you can reach NPM admin over VPN
- you can reach other VPN-only services over VPN
- you have provider console access if something goes wrong

## Security posture after lockdown

In the intended end state, the public internet should see little more than:

- `443/tcp`
- `51820/udp`

Everything else is internal, loopback-only, or VPN-gated.
