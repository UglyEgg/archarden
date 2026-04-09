# Design Tradeoffs and Limitations

This page addresses the obvious hostile review points directly.

## "Why not Ansible or Terraform?"

Fair question. Those are broader and more mature tools for infrastructure work.

Archarden is not presented as a superior alternative. It is a deliberately closer-to-the-system project that grew well beyond its original scope. By the time it outgrew the original intent, the value was no longer just the final machine state. The value was in understanding what happens below the abstraction layer: service activation, network exposure, restart behavior, routing, persistence, and recovery.

In other words, the point is not to deny that better tooling exists. The point is to make the underlying mechanics visible.

## Why Bash?

Because it offered direct host control with minimal dependency overhead, and because the project began life as a much smaller automation script.

That choice carries real costs:

- weaker typing
- more fragile control flow
- easier-to-miss quoting and expansion bugs
- heavier reliance on discipline and review

Several bugs found in this project were classic shell and system-integration bugs. That is not spun as a hidden strength. It is one of the clearest reasons this repository is educational at all.

## Implicit state

State is persisted and resumed, but not modeled as a formal state machine. That is practical for the current scope and also one of the clearest limits of the design.

The current model is understandable for a single host. It is not the same thing as a formal convergence engine.

## Tight coupling

WireGuard, systemd, Podman, NPM, and service bootstrap are coupled in places. That increases precision and decreases portability.

The upside is that the trust boundaries and lifecycle are explicit. The downside is that changes in one layer can surface in another in non-obvious ways.

## Testing limitations

The testing story is not yet what a broader team-operated platform would want. There is useful validation, but not the kind of fully repeatable integration harness that would justify stronger claims.

Pretending otherwise would be nonsense.

## Security limitations

The security posture is materially better than a casually exposed VPS, but it is still an opinionated self-hosted design, not a formally audited platform.

The security story here is strongest when framed as attack-surface reduction and clearer trust boundaries, not as universal hardening doctrine.

## Why publish it anyway?

Because the project demonstrates systems thinking, the rough edges teach something real, and there is value in sharing an honest artifact that sits between a toy script and a polished infrastructure platform.
