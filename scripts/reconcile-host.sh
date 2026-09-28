#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or via sudo." >&2
  exit 1
fi

command -v tailscale >/dev/null
command -v jq >/dev/null

disabled_motd_json=${CLARA_DISABLED_UPDATE_MOTD_SCRIPTS:-[]}
jq -e '
  type == "array" and
  all(.[]; type == "string" and test("^[A-Za-z0-9_-]+$"))
' <<<"$disabled_motd_json" >/dev/null

mapfile -t disabled_motd_scripts < <(jq -r '.[]' <<<"$disabled_motd_json")
for script in "${disabled_motd_scripts[@]}"; do
  script_path="/etc/update-motd.d/$script"
  [[ -e $script_path ]] || {
    echo "Host reconciliation failed: $script_path does not exist." >&2
    exit 1
  }
  chmod a-x "$script_path"
  rm -f "/run/motd.d/$script"
done
rm -f /run/motd.dynamic

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

# Deploy workflows git-fetch over these aliases; a MITM'd GitHub would run code on clara.
deploy_ssh_config=/home/cloudgenius/.ssh/config
if [[ -f /tmp/ssh_known_hosts ]]; then
  install -m 0644 /tmp/ssh_known_hosts /etc/ssh/ssh_known_hosts
  rm -f /tmp/ssh_known_hosts
fi
if [[ -f $deploy_ssh_config ]]; then
  sed -i -E \
    -e 's/^([[:space:]]*)StrictHostKeyChecking[[:space:]]+no$/\1StrictHostKeyChecking yes/' \
    -e '/^[[:space:]]*UserKnownHostsFile[[:space:]]+\/dev\/null$/d' \
    "$deploy_ssh_config"
fi
mapfile -t github_aliases < <(awk '$1 == "Host" && $2 ~ /^github-/ { print $2 }' "$deploy_ssh_config" 2>/dev/null)
for alias in "${github_aliases[@]}"; do
  probe=$(sudo -u cloudgenius ssh -o BatchMode=yes -o ConnectTimeout=10 \
    -o PreferredAuthentications=none -T "$alias" 2>&1 || true)
  if grep -q 'Host key verification failed' <<<"$probe"; then
    echo "Host reconciliation failed: GitHub host key mismatch via $alias." >&2
    exit 1
  fi
done
if grep -Eq '^[[:space:]]*(StrictHostKeyChecking[[:space:]]+no|UserKnownHostsFile[[:space:]]+/dev/null)$' \
    "$deploy_ssh_config" 2>/dev/null; then
  echo "Host reconciliation failed: $deploy_ssh_config still disables host-key checking." >&2
  exit 1
fi

systemctl enable --now tailscaled
tailscale set --hostname="${CLARA_HOSTNAME:-clara}" --ssh=false

backend_state=$(tailscale status --json | jq -r '.BackendState')
tailscale_ssh=$(tailscale debug prefs | jq -r '.RunSSH')
sshd_state=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd)
fail2ban_state=$(systemctl is-active fail2ban)
nginx_logpaths=$(fail2ban-client get nginx-botsearch logpath)
ssh_journalmatch=$(fail2ban-client get sshd journalmatch)

for script in "${disabled_motd_scripts[@]}"; do
  if [[ -x /etc/update-motd.d/$script || -e /run/motd.d/$script ]]; then
    echo "Host reconciliation failed: MOTD script $script is not disabled." >&2
    exit 1
  fi
done

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
