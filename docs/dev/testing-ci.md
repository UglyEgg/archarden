# Testing and CI

## Current reality

Testing exists, but the test story is not yet comprehensive enough for broad confidence across all lifecycle and networking cases.

## What strong future testing would include

- idempotency checks across reruns
- fixture-based rendering tests for generated files
- WireGuard config generation tests
- systemd unit content regression checks
- container bring-up smoke tests in disposable environments
