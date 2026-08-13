#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or via sudo." >&2
  exit 1
fi

command -v tailscale >/dev/null
command -v jq >/dev/null

masked_units_json=${CLARA_MASKED_SYSTEMD_UNITS:-[]}
jq -e '
  type == "array" and
  all(.[]; type == "string" and test("^[A-Za-z0-9_.@-]+\\.(service|socket|timer|path|target)$"))
' <<<"$masked_units_json" >/dev/null

mapfile -t masked_units < <(jq -r '.[]' <<<"$masked_units_json")
for unit in "${masked_units[@]}"; do
  systemctl mask --now "$unit"
  systemctl reset-failed "$unit" 2>/dev/null || true
done

if [[ -f /tmp/00-clara.conf ]]; then
  install -m 0644 /tmp/00-clara.conf /etc/fail2ban/jail.d/00-clara.conf
  rm -f /tmp/00-clara.conf
fi
systemctl enable --now fail2ban
systemctl restart fail2ban

systemctl enable --now tailscaled
tailscale set --hostname="${CLARA_HOSTNAME:-clara}" --ssh=false

backend_state=$(tailscale status --json | jq -r '.BackendState')
tailscale_ssh=$(tailscale debug prefs | jq -r '.RunSSH')
sshd_state=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd)
fail2ban_state=$(systemctl is-active fail2ban)
nginx_logpaths=$(fail2ban-client get nginx-botsearch logpath)
ssh_journalmatch=$(fail2ban-client get sshd journalmatch)

for unit in "${masked_units[@]}"; do
  if [[ $(systemctl is-enabled "$unit" 2>/dev/null || true) != masked ]] ||
    systemctl is-active --quiet "$unit"; then
    echo "Host reconciliation failed: $unit is not masked and inactive." >&2
    exit 1
  fi
done

if [[ $backend_state != Running || $tailscale_ssh != false || $sshd_state != active ||
      $fail2ban_state != active || $nginx_logpaths != *access.log* || $ssh_journalmatch != *ssh.service* ]]; then
  printf 'Host reconciliation failed: backend=%s tailscale_ssh=%s sshd=%s fail2ban=%s\n' \
    "$backend_state" "$tailscale_ssh" "$sshd_state" "$fail2ban_state" >&2
  exit 1
fi

printf 'Host reconciled: backend=%s tailscale_ssh=%s sshd=%s fail2ban=%s\n' \
  "$backend_state" "$tailscale_ssh" "$sshd_state" "$fail2ban_state"
