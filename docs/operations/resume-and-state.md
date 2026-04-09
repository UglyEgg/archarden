# Resume and State

## Persisted inputs

Durable inputs are written to `/var/lib/archarden/answers.params`.

## Resume trigger

A continuation unit resumes pending work after reboot when the pending-args marker exists.

## Tradeoff

This is useful, but it is also one of the architectural weak spots: state is persisted across files and inferred from execution context rather than modeled as a formal state machine.

That is acceptable for a single-node, Bash-driven project, but it is also the first thing a hostile reviewer will notice.
