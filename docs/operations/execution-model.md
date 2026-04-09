# Execution Model

Archarden uses phased execution with resumable state. The point is simple: some host mutations require reboot, and pretending otherwise usually ends in brittle sequencing.

## Model

- **Phase 1** performs most host changes and base service deployment.
- A continuation unit resumes execution after reboot when needed.
- Subsequent operator-facing commands handle credential rotation, notification initialization, export, verification, and lockdown.

## Why it matters

The execution model is one of the clearest examples of this project growing beyond “small script” territory. Once reboots, service bring-up, and post-boot checks enter the picture, execution order becomes a real part of the architecture.
