# Templates Pipeline

Templates drive generated systemd and container artifacts. This keeps repeated unit structure centralized and reduces some duplication.

## Why templates help here

In a Bash-heavy project, templates are one of the few ways to keep generation logic inspectable and deterministic.

## Why templates do not solve everything

They reduce repetition, but they do not provide a formal desired-state model. Generation correctness still depends on shell logic and runtime substitution.
