#!/usr/bin/env bash
set -euo pipefail

missing=0
for file in harden lib/utils.sh config/sysctl_hardening.conf config/tmp.mount config/fail2ban_jail.local config/fail2ban_sshd.local config/sshd_hardening.conf config/firewall_allow.list config/firewall_modules.list config/journald.conf config/vm-tuning.conf config/zram-generator.conf config/disable-units.list templates/containers/nginx-proxy-manager.container templates/containers/gotify.container templates/containers/podman-run-npm.sh; do
  if [[ ! -f "$file" ]]; then
    echo "Missing $file" >&2
    missing=1
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck harden lib/utils.sh templates/containers/podman-run-npm.sh
else
  echo "shellcheck not installed; skipping lint"
fi

exit ${missing}
