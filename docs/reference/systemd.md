# Systemd Units Reference

## Important units

- continuation unit for reboot-aware resume
- root-owned socket proxy units for privileged/VPN-only exposure
- rootless user services under `podmin`
- timer/service pairs for checks and notifications

## Key lesson

Systemd is one of Archarden’s strengths and one of its biggest sources of subtle bugs. That is normal when you are doing more than `enable --now` and actually relying on activation, lifecycle, and namespace behavior.
