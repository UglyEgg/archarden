# Template Reference

Generated artifacts come from `templates/` and are rendered into service/unit files during execution.

High-value template categories:

- systemd helper units
- root-owned socket proxy units
- container/quadlet templates
- ntfy-related helper/service templates

When behavior is surprising, inspect both the template and the rendered file. The bug may be in either layer.
