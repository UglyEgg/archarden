# Phases and Steps

Archarden is step-driven internally, but the operator should think in broader milestones:

- **Bootstrap**: package state, host settings, hardening, service account, base services
- **Resume/finalize**: backups, persisted state cleanup, final reboot sequencing
- **Post-bootstrap operations**: VPN access, credential rotation, notifications, lockdown

The implementation is step-oriented because Bash needs that structure to stay sane. The documentation is phase-oriented because operators care about outcomes, not shell function names.
