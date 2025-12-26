# Archarden – Arch Linux VPS Hardening

Automated hardening for freshly installed Arch Linux VPS instances. The entrypoint `./harden` configures SSH, UFW, fail2ban, journaling, sysctl tuning, tmpfs for `/tmp`, installs Podman templates (NPM and Gotify) with the admin UI bound to localhost, and can auto-resume after an LTS reboot.

## Quick start

Clone and run (recommended):

```bash
git clone https://example.com/archarden.git
cd archarden
sudo ./harden --user admin --pubkey-file /path/to/id_ed25519.pub --keep-ssh-22
```

Dry run preview:

```bash
sudo ./harden --dry-run --skip-firewall-enable
```

> **One-command alternative:** host the repo and use `curl -fsSL https://example.com/harden.sh | sudo bash -s -- [flags]` to invoke the script directly.

## Access model

- The SSH/admin account is defined by `--user`. It is added to the `ssh` group to satisfy sshd `AllowGroups`, its password is locked, and passwordless sudo is granted via `/etc/sudoers.d/90-archarden-ssh-user` (NOPASSWD). SSH access is key-only; ensure you provide a public key.
- Rootless containers and quadlets run as the fixed `podmin` account (no CLI flag). The script creates `podmin` with home `/home/podmin`, shell `/usr/bin/nologin`, a locked password, no membership in `ssh` or `wheel`, and `sshd` explicitly denies SSH for this user.
- All required inputs must be provided as flags; the script does not prompt for missing values. If `${SCRIPT_DIR}/harden.params` exists beside the script, its contents are used as the complete argument list and override any CLI parameters (logged when applied). Passing `--dry-run` on the command line still forces a dry run even when an answer file is present.

## Flags

- `--hostname <name>`: (required) set the system hostname before other changes.
- `--user <name>`: (required) create/ensure admin user (wheel group) exists.
- `--pubkey-file <path>` / `--pubkey "<key>"`: (required) install SSH public key for the admin user.
- `--ssh-port <port>`: set the SSH daemon port (default 2122).
- `--restrict-ssh-cidr <CIDR>`: restrict SSH access in UFW.
- `--keep-ssh-22`: keep port 22 open in UFW after migration.
- `--enable-auditd`: install and enable auditd (optional).
- `--disable-fail2ban`: skip fail2ban setup.
- `--disable-firewall`: skip firewall configuration entirely (alias: `--disable-ufw`).
- `--skip-firewall-enable`: write UFW rules but do not enable them.
- `--dry-run`: print planned actions without changing the system.
- `--version`: show the installed version of archarden.
- `--resume`: internal flag used when the continuation service resumes after the LTS reboot.

## Package selection

The packages the hardener installs are declared in plain text under `config/`:

- `config/packages.list`: baseline packages installed on every run.
- `config/packages.auditd.list`: packages added only when `--enable-auditd` is provided.
- `config/packages.custom.list`: optional local additions without touching the defaults.
- `config/packages.replacements.list`: optional pairs where a requested package should replace an already-installed one (e.g., `iptables iptables-nft`).

Add tools like `neovim`, `bat`, or `eza` by editing `config/packages.custom.list` (or the other lists, if you want to change the defaults) without modifying the script itself. Ingress firewall allows are defined in `config/firewall_allow.list` (defaults to `80/tcp` and `443/tcp`); edit this file to open additional ports.

### Optional service disables

`config/disable-units.list` lists services that will be disabled near the end of Phase 1 if they are currently enabled. Review the WARNING header and confirm each entry is safe to disable for your host before running the hardener; blank lines and `#` comments are ignored.

Static units or timers are stopped if active but not disabled; static timers such as `archlinux-keyring-wkd-sync.timer` are stopped quietly when their paired service is inactive.

SSH access is restricted to the dedicated `ssh` system group (gid < 1000). The admin user created via `--user` is added to both `wheel` (for sudo) and `ssh`; add any other accounts that need SSH access to the `ssh` group before enabling the firewall. If an `ssh` group already exists with a user-level gid, it is converted to a system gid during setup.

## What the hardener does

- Updates packages and installs the lists defined in `config/packages.list` (and `config/packages.auditd.list` when `--enable-auditd` is used). Defaults include `iptables-nft`, `ufw`, `openssh`, `fail2ban`, `pacman-contrib`, `podman`, `slirp4netns`, `fuse-overlayfs`, `netavark`, and `aardvark-dns`.
- Enables `systemd-timesyncd` and persistent journald storage (capped at 100M persistent, 50M runtime, 7-day retention).
- Applies sysctl hardening (rp_filter, disable redirects/source routing, TCP syncookies) and VM tuning (`vm.swappiness=10`, `vm.vfs_cache_pressure=50`), then reloads via `sysctl --system`.
- Mounts `/tmp` as tmpfs with `nodev,nosuid,noexec`.
- Optionally sets the system hostname with `hostnamectl` when `--hostname` is provided.
- Reports enabled services for review.
- Creates the SSH admin (`--user`) with membership in `ssh` and `wheel`, a locked password (key-only login), and passwordless sudo in `/etc/sudoers.d/90-archarden-ssh-user`.
- Hardens SSH via `/etc/ssh/sshd_config.d/10-hardening.conf` and `/etc/ssh/sshd_config.d/10-crypto-hardening.conf`, limits logins to the dedicated `ssh` group, denies SSH for `podmin` (`DenyUsers podmin`), and moves the daemon to a configurable port (**default 2122**) with key-only auth. Validation uses `sshd -t`, the port is verified before firewall changes, and host keys are rotated with backups under `/root/ssh-hostkey-backup/<timestamp>/` (clients must accept the new keys).
- Configures UFW (nftables backend via `iptables-nft`, default deny incoming, allows SSH on the chosen port, allows `config/firewall_allow.list` entries by default). Optional CIDR restriction for SSH and a transition rule for port 22.
- Sets up fail2ban with UFW actions and sshd jail on the hardened SSH port.
- Enforces Podman OCI runtime to `runc` (system containers.conf and `/home/podmin/.config/containers/containers.conf`) and installs/activates rootless quadlets under `/home/podmin/.config/containers/systemd/` for NPM and Gotify using `systemctl --user --machine=podmin@.host` with non-interactive fallbacks.
- Runs Nginx Proxy Manager rootlessly on `127.0.0.1:8080`/`8443` (admin UI on `127.0.0.1:8181`) and proxies privileged ports 80/443 via root-owned `systemd-socket-proxyd` units.
- Configures Gotify rootlessly with resource limits applied via quadlet.
- Enables zram swap via `zram-generator` (25% RAM, zstd, priority 100).
- Ensures linux-lts is installed and set as the GRUB default, reboots once (automatically after a 5-second grace period), and auto-resumes hardening via a systemd oneshot continuation unit. Phase 1 ends with a final reboot (5-second delay) so socket proxies and podmin-managed quadlets come up automatically afterward.

## Safe SSH migration

1. Run `./harden` with your public key. Use `--ssh-port <port>` to pick a custom port (default 2122) and `--keep-ssh-22` for a transition period if desired.
2. The script writes the sshd drop-in, validates config, restarts sshd, and verifies the chosen port is listening **before** enabling UFW.
3. UFW is only enabled after sshd passes validation; port 22 can remain open with `--keep-ssh-22`.
4. Confirm you can log in on the hardened SSH port before closing existing sessions.

## Logging and resume flow

- Phase 0 (pre-reboot) actions log to `/var/log/vps-harden.phase0.log`. The resume command (for manual continuation) is also written there.
- After the automatic reboot into the LTS kernel, the resumed run logs to `/var/log/vps-harden.phase1.log`.
- A friendly summary is written to `/root/vps-harden.log` (or the admin user's home) after completion.
- Phase 1 ends with a final 5-second warning and reboot so podmin-managed quadlets and the socket proxies come up automatically after the hardening run.

## Podman runtime and quadlets

- Rootless unit control uses `systemctl --user --machine=podmin@.host ...` and falls back to `XDG_RUNTIME_DIR=/run/user/<uid>` plus `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/<uid>/bus` so non-interactive invocations succeed even without an existing session bus.
- Quadlets are installed for the fixed `podmin` account under `/home/podmin/.config/containers/systemd/` and managed via the podmin user instance (e.g., `systemctl --user --machine=podmin@.host status nginx-proxy-manager.service`).
- The OCI runtime is forced to `runc` via `/etc/containers/containers.conf` and `/home/podmin/.config/containers/containers.conf`. Verify with `runuser -u podmin -- podman info --format '{{.Host.OCIRuntime.Name}}'` (expected: `runc`).
- Rootless (podmin-run) NPM listens on `127.0.0.1:8080` (HTTP) and `127.0.0.1:8443` (HTTPS) with the admin UI on `127.0.0.1:8181`. Root-owned `systemd-socket-proxyd` units on ports 80/443 forward traffic to the rootless listener; additional public ports require their own socket/proxy pair.
- Gotify runs rootlessly as `podmin` with memory and PID limits applied by the quadlet; manage it the same way with `systemctl --user --machine=podmin@.host`.

## Accessing NPM admin UI

The provided quadlet and helper script bind the NPM admin UI to `127.0.0.1:8181`. To access remotely:

```bash
ssh -L 8181:127.0.0.1:8181 user@server -p 2122  # replace port if you used --ssh-port
```

Then browse to `http://localhost:8181` locally. Public ports 80/443 are handled by root-owned socket proxies that forward to the rootless listeners on 8080/8443; add additional socket/proxy units if you need more public ports.

## Gotify connectivity

Gotify is bound to `127.0.0.1:8090` by default so it is reachable locally or over an SSH tunnel (e.g., `ssh -L 8090:127.0.0.1:8090 user@server -p 2122`). No additional firewall rules are required in this mode. If you rebind Gotify to a non-loopback address, add the desired port (e.g., `8090/tcp`) to `config/firewall_allow.list` before running the hardener so UFW allows inbound access.

## Swap and zram checks

The hardener configures `zram-generator` with a zstd-compressed swap device sized to 25% of RAM and priority 100. Use `swapon --show` to confirm `/dev/zram0` is present and has higher priority than any `/swap/swapfile` entry.

## Rollback / restore

Backups with timestamped `.bak` suffix are created for touched files:

- `/etc/default/ufw`
- `/etc/ssh/sshd_config.d/10-hardening.conf` (if pre-existing)
- `/etc/ssh/sshd_config.d/10-crypto-hardening.conf` (if pre-existing)
- `/etc/systemd/journald.conf`
- `/etc/sysctl.d/99-hardening.conf`
- `/etc/fail2ban/jail.local`
- `/etc/systemd/system/tmp.mount`
- `/root/ssh-hostkey-backup/<timestamp>/` (host keys copied before regeneration)

To roll back:

1. Replace the active file with the latest `.bak` copy (e.g., `cp /etc/sysctl.d/99-hardening.conf.*.bak /etc/sysctl.d/99-hardening.conf`).
2. Reload or restart the affected service (`systemctl restart systemd-journald`, `systemctl restart sshd`, `ufw reload`, etc.).
3. Disable services if desired: `systemctl disable --now ufw fail2ban tmp.mount`.

## Make targets

- `make lint`: run shellcheck on scripts (if available).
- `make dry-run`: preview hardening changes without applying them.
- `make install`: run the hardener normally.

## Tests

Minimal smoke test script is under `tests/smoke.sh` and checks file presence plus optional shellcheck.
