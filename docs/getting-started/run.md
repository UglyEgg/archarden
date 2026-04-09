# Install and Run

## Clone and inspect

```bash
git clone <repo-url>
cd archarden
less README.md
```

## Dry run first

```bash
sudo ./archarden apply --dry-run --skip-firewall-enable   --hostname venger   --user admin   --pubkey-file /path/to/id_ed25519.pub
```

## Real run

```bash
sudo ./archarden apply   --hostname venger   --user admin   --pubkey-file /path/to/id_ed25519.pub   --le-email admin@example.com   --ntfy-public-host ntfy.example.com
```

## After phase 1

1. Confirm the host rebooted and came back cleanly.
2. Export WireGuard configs with `./archarden wg export`.
3. Join the VPN from your workstation.
4. Reach VPN-only admin interfaces.
5. Rotate credentials and initialize notifications.
6. Only then consider lockdown.
