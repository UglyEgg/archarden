# Post-install next steps

This guide begins after `archarden` completes all phases successfully and the new admin logs in.

## 1. Validate the host

```bash
sudo archarden doctor
sudo archarden verify
```

Both should pass before continuing.

## 2. Retrieve WireGuard client config

```bash
ls /etc/wireguard/clients
```

Copy the desired client config to your workstation or phone and import it.

## 3. Connect over WireGuard

Once connected, verify the VPN path:

```bash
ping 10.66.66.1
```

Internal admin access should then work over the VPN.

## 4. Lock SSH to WireGuard only

Do not edit `sshd_config` by hand. Use Archarden:

```bash
sudo archarden lockdown
```

After lockdown, SSH should only be reachable over WireGuard on the configured SSH port.

## 5. Access internal services over WireGuard

- NPM admin: `http://10.66.66.1:8181`
- Uptime Kuma: `http://10.66.66.1:3001`

`ntfy` is the only service intended to be exposed publicly.

## 6. Check running containers

```bash
sudo -u podmin sh -lc 'cd / && XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user status nginx-proxy-manager uptime-kuma ntfy --no-pager -l'
sudo -u podmin sh -lc 'cd / && podman ps'
```

## 7. Configure DNS

Create a public DNS record for the ntfy endpoint:

- `ntfy.<your-domain>` → your VPS public IP

For initial setup, keep the Cloudflare record DNS-only until NPM is working.

## 8. Create the NPM host for ntfy

In NPM admin, create one proxy host:

- Domain: `ntfy.<your-domain>`
- Scheme: `http`
- Forward Hostname/IP: `ntfy`
- Forward Port: `80`

Recommended NPM options:

- Websocket Support: **On**
- Block Common Exploits: **On**
- Cache Assets: **Off**

## 9. Request the SSL cert in NPM

Use DNS challenge with Cloudflare:

- Provider: Cloudflare
- Token permissions:
  - Zone → DNS → Edit
  - Zone → Zone → Read
- Scope: your zone only

Use a valid real email address for Let's Encrypt.

## 10. Validate ntfy

Inspect generated notification config:

```bash
sudo cat /etc/archarden/notify.env
```

Inspect generated ntfy config:

```bash
sudo -u podmin cat /home/podmin/.config/archarden/ntfy/server.yml
```

`web-root: disable` and the absence of any wildcard `*:<topic>:ro` rule are expected in the hardened default configuration.

## 11. Validate Kuma

Login using the generated credentials:

```bash
sudo cat /var/lib/archarden/secrets/kuma_admin_user
sudo cat /var/lib/archarden/secrets/kuma_admin_pass
```

## 12. Final expected public surface

Publicly reachable:

- `443/tcp`
- WireGuard UDP port (default `51820/udp`)

Everything else should be localhost- or WireGuard-only.
