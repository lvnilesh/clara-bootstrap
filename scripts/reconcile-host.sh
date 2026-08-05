#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or via sudo." >&2
  exit 1
fi

command -v tailscale >/dev/null
command -v jq >/dev/null

systemctl enable --now tailscaled
tailscale set --hostname="${CLARA_HOSTNAME:-clara}" --ssh=false

backend_state=$(tailscale status --json | jq -r '.BackendState')
tailscale_ssh=$(tailscale debug prefs | jq -r '.RunSSH')
sshd_state=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd)

if [[ $backend_state != Running || $tailscale_ssh != false || $sshd_state != active ]]; then
  printf 'Host reconciliation failed: backend=%s tailscale_ssh=%s sshd=%s\n' \
    "$backend_state" "$tailscale_ssh" "$sshd_state" >&2
  exit 1
fi

printf 'Host reconciled: backend=%s tailscale_ssh=%s sshd=%s\n' \
  "$backend_state" "$tailscale_ssh" "$sshd_state"
