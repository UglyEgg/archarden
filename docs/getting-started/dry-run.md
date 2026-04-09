# Dry Run

Dry run exists so you can inspect intended mutations before you mutate the host.

## What dry run is good for

- verifying flag parsing
- reviewing rendered files and commands
- spotting obvious listener/firewall mistakes
- confirming resume-state inputs look sane

## What dry run does not prove

- that services will start successfully
- that WireGuard will handshake from your workstation
- that container images behave the same way later
- that every interactive/external dependency is satisfied

Use dry run as a planning tool, not as a substitute for staged testing.
