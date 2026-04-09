# Filesystem Layout

## Important paths

- `/var/lib/archarden/answers.params` — durable answers
- `/var/lib/archarden/wireguard/` — peer state and exports
- `/etc/archarden/` — generated notify/env config
- `/home/podmin/.config/containers/systemd/` — rootless quadlets
- `/home/podmin/.config/archarden/` — service env files
- `/home/podmin/.local/share/uptime-kuma/` — Kuma data
- `/etc/systemd/system/` — root-owned helper/socket units

The path layout is part of the product. Predictable paths are operational documentation.
