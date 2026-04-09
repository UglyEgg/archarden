# Configuration

Archarden is configured primarily through CLI flags, with durable answers persisted to `/var/lib/archarden/answers.params`.

## Precedence

1. CLI flags
2. persisted answers file
3. legacy local params file

## Important categories

- host identity: hostname, admin user, SSH key
- ingress/public naming: Let's Encrypt email, public hostnames
- WireGuard: peer count, interface settings
- optional controls: auditd, firewall, fail2ban, dry-run

## Philosophy

This is explicit configuration, not a hidden policy engine. The downside is verbosity. The upside is that another operator can see what was requested without spelunking through ten abstraction layers.
