#!/usr/bin/env bash
# clara-bootstrap — provision a fresh Ubuntu 24.04 VM into a "ready-to-deploy"
# clara clone on any cloud (Azure, Hetzner, DigitalOcean, Linode, …).
#
# Usage (as root on a fresh VM):
#   curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | bash
#
# Or, with a custom SSH pubkey for the cloudgenius user:
#   curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh \
#     | CLOUDGENIUS_SSH_KEYS="$(curl -s https://github.com/lvnilesh.keys)" bash
#
# What this DOES:
#   • sets hostname to `clara`
#   • installs docker, docker-compose plugin, nginx, cloudflared, git, jq, python3
#   • creates cloudgenius user (uid 1000, groups: sudo docker)
#   • adds NOPASSWD sudo for cloudgenius
#   • plants authorized_keys from CLOUDGENIUS_SSH_KEYS env or github.com/lvnilesh.keys
#   • enables docker + nginx systemd
#
# What this does NOT do:
#   • CF Tunnel credentials (deployed by clara-cloudflared workflow via GH Secret)
#   • Deploy keys for private repos (generated per-repo, see MIGRATION.md)
#   • Container data restoration (rsync from old clara, see MIGRATION.md)
#
# Env overrides:
#   CLARA_HOSTNAME    — hostname to set (default: clara)
#   CLOUDGENIUS_SSH_KEYS — admin authorized_keys (default: fetched from github.com/lvnilesh.keys)
#   RUNNER_SSH_KEYS      — GH Actions runner keys (appended to authorized_keys)
#   CLARA_IGNOREIP       — space-separated CIDRs to exempt from fail2ban
#   • Firewall/NSG rules (cloud-specific — see MIGRATION.md)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root or via sudo." >&2
  exit 1
fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- Preflight: refuse to run if the target uid 1000 user is currently logged in ---
# `usermod -l` renames the account, and it fails hard ("user X is currently used
# by process Y") if the user is logged in (e.g. you SSH'd in as `azureuser` on
# Azure or `ubuntu` elsewhere and are now running this script under sudo).
# Remedies:
#   1. Run from cloud-init runcmd (list form, so it uses bash — see README).
#   2. `az vm run-command invoke` / `hcloud server ssh` after boot but before
#      the default user has an active SSH session.
#   3. Set CLARA_ALLOW_KILL_USER_1000=1 and this script will `loginctl
#      terminate-user` + `pkill -KILL -u` on uid 1000 first (destroys your SSH
#      session — you'll need out-of-band console access to re-connect).
DEFAULT_USER_NAME=$(getent passwd 1000 | cut -d: -f1 || true)
if [[ -n "$DEFAULT_USER_NAME" && "$DEFAULT_USER_NAME" != "cloudgenius" ]]; then
  if pgrep -u 1000 >/dev/null 2>&1; then
    if [[ "${CLARA_ALLOW_KILL_USER_1000:-}" == "1" ]]; then
      log "PREFLIGHT: killing all processes for uid 1000 ($DEFAULT_USER_NAME) — will drop your SSH session"
      loginctl terminate-user 1000 2>/dev/null || true
      pkill -KILL -u 1000 2>/dev/null || true
      sleep 2
    else
      cat >&2 <<PREFLIGHT_ERR

ERROR: uid 1000 ($DEFAULT_USER_NAME) has active processes — cannot rename to cloudgenius.

If you SSH'd in as $DEFAULT_USER_NAME and are running this via sudo, usermod -l
will fail. Choose one of:

  (a) Run from cloud-init BEFORE any user logs in. Use runcmd list form so
      the script is invoked with bash (not dash):

        #cloud-config
        runcmd:
          - [bash, -c, "curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | bash"]

  (b) Run via out-of-band execution after boot, e.g. on Azure:
        az vm run-command invoke -g <RG> -n <VM> --command-id RunShellScript \
          --scripts "curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | bash"

  (c) Force this script to kill uid 1000's sessions first (loses your SSH):
        CLARA_ALLOW_KILL_USER_1000=1 bash bootstrap.sh
      Then reconnect via cloud console / OOB to finish install.

PREFLIGHT_ERR
      exit 1
    fi
  fi
fi

log "1/9  hostname → ${CLARA_HOSTNAME:-clara}"
hostnamectl set-hostname "${CLARA_HOSTNAME:-clara}"

log "2/9  apt update + upgrade"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get -o Dpkg::Options::="--force-confold" -y upgrade

log "3/9  install baseline packages"
apt-get install -y \
  curl wget ca-certificates gnupg lsb-release \
  git python3 python3-pip jq \
  docker.io docker-compose-v2 \
  nginx \
  fail2ban \
  ufw

systemctl enable --now docker
systemctl enable --now nginx

log "4/9  install cloudflared"
if ! command -v cloudflared >/dev/null; then
  mkdir -p /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y
  apt-get install -y cloudflared
fi

log "5/9  create cloudgenius user (uid 1000)"
if ! id cloudgenius >/dev/null 2>&1; then
  # If uid 1000 is taken by the default cloud user (ubuntu/azureuser), rename.
  DEFAULT_USER=$(getent passwd 1000 | cut -d: -f1 || true)
  if [[ -n "$DEFAULT_USER" && "$DEFAULT_USER" != "cloudgenius" ]]; then
    usermod -l cloudgenius "$DEFAULT_USER"
    usermod -d /home/cloudgenius -m cloudgenius
    groupmod -n cloudgenius "$DEFAULT_USER"
  else
    useradd -m -u 1000 -s /bin/bash cloudgenius
  fi
fi
usermod -aG sudo,docker cloudgenius

log "6/9  passwordless sudo for cloudgenius"
echo 'cloudgenius ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-cloudgenius
chmod 0440 /etc/sudoers.d/90-cloudgenius

log "7/9  seed authorized_keys"
sudo -u cloudgenius mkdir -p /home/cloudgenius/.ssh
chmod 700 /home/cloudgenius/.ssh
KEYS="${CLOUDGENIUS_SSH_KEYS:-}"
if [[ -z "$KEYS" ]]; then
  KEYS=$(curl -fsSL https://github.com/lvnilesh.keys 2>/dev/null || true)
fi
if [[ -n "$KEYS" ]]; then
  echo "$KEYS" > /home/cloudgenius/.ssh/authorized_keys
  chown cloudgenius:cloudgenius /home/cloudgenius/.ssh/authorized_keys
  chmod 600 /home/cloudgenius/.ssh/authorized_keys
  echo "  planted $(echo "$KEYS" | wc -l) key(s)"
fi
# GH Actions runner keys (one per repo runner) so workflows can ssh cloudgenius@clara
if [[ -n "${RUNNER_SSH_KEYS:-}" ]]; then
  echo "$RUNNER_SSH_KEYS" >> /home/cloudgenius/.ssh/authorized_keys
  echo "  planted $(echo "$RUNNER_SSH_KEYS" | wc -l) runner key(s)"
fi

log "8/9  install clara fail2ban jail config"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ -f "$SCRIPT_DIR/etc/fail2ban/jail.d/00-clara.conf" ]; then
  install -m 0644 "$SCRIPT_DIR/etc/fail2ban/jail.d/00-clara.conf" /etc/fail2ban/jail.d/00-clara.conf
  systemctl enable --now fail2ban
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
elif [ -n "${CLARA_BOOTSTRAP_URL:-}" ]; then
  curl -fsSL "$CLARA_BOOTSTRAP_URL/etc/fail2ban/jail.d/00-clara.conf" \
    -o /etc/fail2ban/jail.d/00-clara.conf
  chmod 0644 /etc/fail2ban/jail.d/00-clara.conf
  systemctl enable --now fail2ban
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
else
  # Piped install without repo context — fetch from GitHub raw.
  curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/etc/fail2ban/jail.d/00-clara.conf \
    -o /etc/fail2ban/jail.d/00-clara.conf
  chmod 0644 /etc/fail2ban/jail.d/00-clara.conf
  systemctl enable --now fail2ban
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
fi


# CLARA_IGNOREIP: space-separated CIDRs to exempt from fail2ban.
# Example: CLARA_IGNOREIP="192.168.1.0/24 73.221.218.159/32"
if [[ -n "${CLARA_IGNOREIP:-}" ]]; then
  cat > /etc/fail2ban/jail.d/01-ignoreip.conf <<IPCFG
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${CLARA_IGNOREIP}
IPCFG
  systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban
  echo "  ignoreip set: ${CLARA_IGNOREIP}"
fi

log "9/9  prep ~/src for repo clones"
sudo -u cloudgenius mkdir -p /home/cloudgenius/src

log "DONE. Next steps (from surf or admin machine):"
cat <<NEXT

  # 1. Test SSH:
  ssh cloudgenius@<new-clara-ip>

  # 2. Generate + register deploy keys for each private repo (from surf):
  for repo in clara-nginx clara-cloudflared authentik-clara pangolin-clara; do
    ssh cloudgenius@<new-clara-ip> "ssh-keygen -t ed25519 -f ~/.ssh/\${repo//-/_}_deploy_key -N '' -C 'clara-\${repo}-deploy'"
    PUB=\$(ssh cloudgenius@<new-clara-ip> "cat ~/.ssh/\${repo//-/_}_deploy_key.pub")
    gh api -X POST /repos/lvnilesh/\$repo/keys -f "title=clara-\$repo-deploy" -f "key=\$PUB" -F "read_only=true"
    ssh cloudgenius@<new-clara-ip> "cat >> ~/.ssh/config" <<CFG
Host github-\$repo
  HostName github.com
  IdentityFile ~/.ssh/\${repo//-/_}_deploy_key
  IdentitiesOnly yes
CFG
  done

  # 3. If migrating from old clara: rsync container state
  rsync -avP old-clara:src/authentik-clara/{data,database} new-clara:src/authentik-clara/
  rsync -avP old-clara:src/pangolin-clara/config           new-clara:src/pangolin-clara/
  # (+ coursebook, ghost, multistream databases as needed)

  # 4. Push a no-op commit to each repo to trigger deploy:
  for repo in clara-cloudflared clara-nginx authentik-clara pangolin-clara; do
    (cd ~/src/\$repo && git commit --allow-empty -m "trigger deploy on new clara" && git push)
  done

  # 5. Update DNS for gerbil WireGuard:
  #    clara.cloudgeni.us  A  <new-clara-ip>  (grey cloud)

  # 6. Open cloud firewall / NSG:
  #    inbound TCP 22, TCP 80, TCP 443, UDP 51820, UDP 21820

NEXT
