# AGENTS.md (Bash 5.0+)

## Purpose

You are an automated coding agent working in this repository.
Priorities: correctness, safety, minimal change surface, and easy review.

## Operating rules

- Prefer small, reviewable changes over broad refactors.
- Read before writing: inspect existing scripts, conventions, and CI.
- Do not change public CLI interfaces, dependencies, or CI without explicit request.
- No drive-by formatting; touch only what’s required.
- Never access or print secrets. If a secret is required, request it via the env var name only.

## Environment assumptions

- Bash: 5.0+
- Shell scripts should be runnable on Linux; check repo for macOS/BSD constraints.

## Script conventions

- Use `#!/usr/bin/env bash` shebang.
- Use strict mode unless the repo indicates otherwise:
  - `set -euo pipefail`
  - `IFS=$'\n\t'`
- Quote variables by default: `"${var}"`
- Prefer `printf` over `echo -e`.
- Prefer functions + `main` entrypoint; keep global state minimal.
- Validate inputs; provide clear usage/help output.

## Portability and dependencies

- Prefer POSIX/GNU common tools; if GNU-specific behavior is required (e.g., `sed -r` vs `sed -E`), document it.
- Use `mktemp` for temp files; clean up with `trap`.

## Quality checks

- If present, use these tools:
  - `shellcheck` for lint
  - `shfmt` for formatting
- If CI defines commands, follow those.

## Safety guardrails

- Avoid destructive defaults. If a command can delete/overwrite, require explicit flags and confirmation.
- When running remote operations, default to dry-run where feasible.
- Never modify the user’s system outside the repo unless explicitly requested.

## Completion format

When you are done, respond with:

1. **Changes**: files changed + 1–2 bullets each
2. **Verify**: exact commands
3. **Notes/Risks**: edge cases, follow-ups
