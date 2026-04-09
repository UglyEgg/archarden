# Architecture Rules

1. Public exposure should stay minimal and intentional.
2. VPN-only admin surfaces should remain explicit.
3. Service ownership boundaries should remain obvious.
4. State persistence must be inspectable.
5. Cleverness is guilty until proven useful.

Those rules exist because the project has already demonstrated what happens when a shell/systemd stack gets too clever without guardrails.
