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
sudo ./harden --dry-run --non-interactive --skip-firewall-enable
```

> **One-command alternative:** host the repo and use `curl -fsSL https://example.com/harden.sh | sudo bash -s -- [flags]` to invoke the script directly.

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
- `--disable-linger`: disable lingering for the admin user (enabled by default).
- `--skip-firewall-enable`: write UFW rules but do not enable them.
- `--enable-linger`: enable lingering for the admin user (recommended for rootless Podman).
- `--hostname <name>`: set the system hostname before other changes.
- `--dry-run`: print planned actions without changing the system.
- `--non-interactive`: fail if required inputs (like pubkey) are missing.
- `--version`: show the installed version of archarden.
- `--resume`: internal flag used when the continuation service resumes after the LTS reboot.

## Package selection

The packages the hardener installs are declared in plain text under `config/`:

- `config/packages.list`: baseline packages installed on every run.
- `config/packages.auditd.list`: packages added only when `--enable-auditd` is provided.
- `config/packages.custom.list`: optional local additions without touching the defaults.

Add tools like `neovim`, `bat`, or `eza` by editing `config/packages.custom.list` (or the other lists, if you want to change the defaults) without modifying the script itself. Ingress firewall allows are defined in `config/firewall_allow.list` (defaults to `80/tcp` and `443/tcp`); edit this file to open additional ports.

SSH access is restricted to the dedicated `ssh` system group (gid < 1000). The admin user created via `--user` is added to both `wheel` (for sudo) and `ssh`; add any other accounts that need SSH access to the `ssh` group before enabling the firewall. If an `ssh` group already exists with a user-level gid, it is converted to a system gid during setup.

## What the hardener does

- Updates packages and installs the lists defined in `config/packages.list` (and `config/packages.auditd.list` when `--enable-auditd` is used). Defaults include `iptables-nft`, `ufw`, `openssh`, `fail2ban`, `pacman-contrib`, `podman`, `slirp4netns`, `fuse-overlayfs`, `netavark`, and `aardvark-dns`.
- Enables `systemd-timesyncd` and persistent journald storage.
- Applies sysctl hardening (rp_filter, disable redirects/source routing, TCP syncookies).
- Mounts `/tmp` as tmpfs with `nodev,nosuid,noexec`.
- Optionally sets the system hostname with `hostnamectl` when `--hostname` is provided.
- Reports enabled services for review.
- Hardens SSH via `/etc/ssh/sshd_config.d/10-hardening.conf`, limits logins to the dedicated `ssh` group, and moves the daemon to a configurable port (**default 2122**) with key-only auth. Validation uses `sshd -t` and the port is verified before firewall changes.
- Configures UFW (nftables backend via `iptables-nft`, default deny incoming, allows SSH on the chosen port, allows `config/firewall_allow.list` entries by default). Optional CIDR restriction for SSH and a transition rule for port 22.
- Sets up fail2ban with UFW actions and sshd jail on the hardened SSH port.
- Installs Podman templates: NPM with the admin UI bound to `127.0.0.1:8181` and Gotify bound to `127.0.0.1:8090`.
- Ensures linux-lts is installed and set as the GRUB default, reboots once, and auto-resumes hardening via a systemd oneshot continuation unit. A final emoji summary is printed after completion.

## Safe SSH migration

1. Run `./harden` with your public key. Use `--ssh-port <port>` to pick a custom port (default 2122) and `--keep-ssh-22` for a transition period if desired.
2. The script writes the sshd drop-in, validates config, restarts sshd, and verifies the chosen port is listening **before** enabling UFW.
3. UFW is only enabled after sshd passes validation; port 22 can remain open with `--keep-ssh-22`.
4. Confirm you can log in on the hardened SSH port before closing existing sessions.

## Accessing NPM admin UI

The provided quadlet and helper script bind the NPM admin UI to `127.0.0.1:8181`. To access remotely:

```bash
ssh -L 8181:127.0.0.1:8181 user@server -p 2122  # replace port if you used --ssh-port
```

Then browse to `http://localhost:8181` locally. The public ports 80/443 remain published for proxied sites only.

## Rollback / restore

Backups with timestamped `.bak` suffix are created for touched files:

- `/etc/default/ufw`
- `/etc/ssh/sshd_config.d/10-hardening.conf` (if pre-existing)
- `/etc/systemd/journald.conf`
- `/etc/sysctl.d/99-hardening.conf`
- `/etc/fail2ban/jail.local`
- `/etc/systemd/system/tmp.mount`

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
