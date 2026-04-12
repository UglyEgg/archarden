# archarden – Arch Linux VPS Hardening

`archarden` is a repeatable host-bootstrap and service-hardening tool for freshly installed Arch Linux VPS instances. It turns a new server into a VPN-gated, reverse-proxied platform with a deliberately small public attack surface, rootless service hosting, and an opinionated operational model.

The entrypoint `./archarden` hardens SSH, UFW, fail2ban, journaling, sysctl, and `/tmp`; provisions WireGuard for private administration; deploys rootless Podman-managed services (Nginx Proxy Manager, ntfy, Uptime Kuma); and uses resumable, phased execution so required reboots do not turn the host into a half-configured snowflake.

## Why this project exists

This started as a much smaller automation script.

Instead of abstracting the rough edges away, the project kept following them downward: service activation, exposure boundaries, rootless container networking, WireGuard routing, reboot-aware execution, and the awkward reality that host security is more than opening a firewall and installing fail2ban.

Tools like Ansible and Terraform solve broader provisioning problems well. `archarden` is not presented as a superior replacement for them. It is better read as a deliberately closer-to-the-system project that exposes what those tools usually abstract: lifecycle, routing, trust boundaries, and failure modes.

In practice, the result should read less like "a script that installs packages" and more like a small, opinionated systems engineering project.

## Architecture at a glance

- **Public entry points**: reverse-proxied application traffic on `443/tcp`; WireGuard on `51820/udp`.
- **Private admin plane**: VPN-only access to NPM admin, Uptime Kuma, and post-lockdown SSH.
- **Service model**: rootless Podman under the dedicated `podmin` account, with root-owned socket proxies where privileged or WireGuard-only exposure is required.
- **Hardening model**: key-only SSH, default-deny firewall posture, fail2ban, sysctl tightening, persistent journald, tmpfs `/tmp`, and phased reboot-aware execution.
- **Ops model**: built-in `verify`, `doctor`, backup archiving, WireGuard client export, notification hooks, and an explicit lockdown stage.

## Read this repo the right way

A few scope notes upfront:

- This is **single-host** and intentionally opinionated.
- This is **not** a cluster orchestrator or a universal provisioning framework.
- This is **not** a definitive hardening guide.
- This **is** a useful working project and a useful way to understand how Linux layers interact when the abstractions run out.

If all you take away from it is that secure server setup is mostly about exposure boundaries, service ownership, and trust assumptions rather than one magic package, it has done its job.

## Operator runbook

See **docs/operator-flow.md** for the complete start-to-end process (Phase 1 apply → WireGuard join → Phase 2 creds/notify → Phase 3 lockdown).

See **docs/security.md** for the security architecture, exposure model, and further-hardening ideas.


## ntfy defaults

Archarden provisions ntfy as a rootless container behind NPM with `behind-proxy: true`, `auth-default-access: deny-all`, generated admin and publisher credentials, a generated publisher token, and a randomized topic. Anonymous clients are granted read-only access only to that randomized topic so the Android app can subscribe without exposing write access. The generated values are stored under `/var/lib/archarden/secrets/` and `/etc/archarden/notify.env`.


## Firewall backend note

On current Arch Linux, the `iptables` package provides the nft-backed implementation.
Archarden prefers `iptables` and only treats `iptables-legacy` as an explicit fallback/legacy choice.
