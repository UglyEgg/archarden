# Module Map

- `lib/steps.sh` — orchestration steps
- `lib/runner.sh` — step/phase execution harness
- `lib/socket_proxy.sh` — root-owned proxy/socket exposure helpers
- `lib/podman_rootless.sh` — fallback rootless service plumbing
- `lib/quadlet.sh` — quadlet generation and lifecycle helpers
- `lib/wireguard.sh` — WireGuard generation/export
- `lib/doctor.sh` — diagnostics
- `lib/verify.sh` — exposure verification
- `lib/secrets.sh` — secret storage helpers

This map exists because shell projects become archaeology sites faster than compiled ones.
