# Potential Future Roadmap

These are the highest-value improvements that would strengthen Archarden without pretending it should become an everything-tool.

## 1. Explicit state model

Today, state is inferred from persisted files and execution context. A more formal state file or transition model would make recovery behavior easier to reason about and easier to test.

This is the most direct way to make the current execution model less dependent on operator familiarity.

## 2. Stronger idempotency guarantees

Document which operations are safe to rerun, then enforce those assumptions more systematically. Right now, many flows are rerunnable in practice, but not all guarantees are first-class.

A stronger rerun story would make the project easier to trust and easier to modify.

## 3. Clearer service-boundary documentation

Document which components depend on which other components and which interfaces are public, VPN-only, or local-only. The architecture already implies this; the roadmap item is to make it explicit enough that another operator does not have to infer as much.

## 4. More formal threat and trust-boundary documentation

Expand the current security material into a clearer threat and assumption document covering key management, secret handling, ingress assumptions, trust boundaries, and recovery expectations.

The goal is not to sound more severe. The goal is to make the existing design legible.

## 5. Remove accidental complexity where possible

A good example was the socket-proxy chain. It worked, then failed, then proved too clever in places. Future work should keep trimming layers that do not clearly earn their keep.

This is not anti-complexity theater. Some layers are necessary. The point is to stop paying for cleverness that does not buy anything.

## Non-goal

The roadmap is not "reinvent all of Ansible in Bash." The goal is to strengthen the current project while respecting what it actually is: a single-host bootstrap and operations project that doubles as a close-to-the-system learning platform.
