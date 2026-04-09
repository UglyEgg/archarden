# Troubleshooting

## High-value checks

### WireGuard

```bash
sudo wg show
ip route
```

### Listeners

```bash
ss -lntup
```

### systemd

```bash
systemctl status <unit> --no-pager -l
journalctl -u <unit> -n 100 --no-pager
```

### rootless Podman

```bash
sudo -H -u podmin sh -lc 'cd / && podman ps -a'
```

## Typical failure classes

- service healthy, but wrong bind/listener path
- socket activation unit misconfigured
- resumed phase collides with its own carrier unit
- WireGuard route/peer generation mistake
- admin API/bootstrap path too brittle for automation
