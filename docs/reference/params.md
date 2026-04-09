# Params File Reference

The params file is a convenience input format and operator reference, not the whole truth of runtime state.

## Canonical persisted inputs

After a run, `/var/lib/archarden/answers.params` is the important durable artifact.

## Practical rule

Use the params file to describe intent; use the answers file to inspect what the system believes was actually applied.
