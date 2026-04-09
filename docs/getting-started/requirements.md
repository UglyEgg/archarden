# Requirements

## Supported target

- Fresh or near-fresh **Arch Linux** VPS
- Root access
- Stable console or provider rescue access in case networking is misconfigured

## Operator prerequisites

You should be comfortable with:

- systemd unit inspection and journal reading
- SSH key management
- basic firewall concepts
- WireGuard client usage
- rootless Podman basics

## Practical requirements

- A public hostname and DNS control for proxied services
- An SSH public key for the admin user
- A workstation capable of importing WireGuard configs
- Enough patience to test before running lockdown

## Strong recommendation

Do not run this first on your favorite irreplaceable server. Use a disposable VPS, break it, learn from it, then rerun.
