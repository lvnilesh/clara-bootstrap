# Migrating clara to a new cloud

15-minute forklift for moving clara from Azure to Hetzner / DigitalOcean /
Linode / anywhere with an Ubuntu 24.04 VM.

## Prereqs

- New VM: Ubuntu 24.04, minimum 4 GB RAM / 40 GB disk, root SSH access, public IPv4.
- `gh` CLI logged in on your admin machine (surf).
- Cloudflare API token with `Zone: DNS: Edit` scope.
- Old clara still online during migration (for rsync).

## Steps

### 1. Provision the new VM

Whichever cloud UI you like. Ubuntu 24.04. Any size ≥ 4 GB RAM. Public IP.

### 2. Bootstrap OS

SSH in as root (or via cloud's initial-user):

```bash
curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | sudo bash
```

Installs docker, nginx, cloudflared, creates `cloudgenius` user with your
SSH keys from https://github.com/lvnilesh.keys.

Log out, log back in as `cloudgenius@new-clara-ip`. Confirm docker + nginx
run.

### 3. Restore docker registry credentials

Some containers pull from a private registry (`reg.home.cloudgeni.us` — home
registry for coursebook builds) and push to Docker Hub. Restore the docker
auth config to the new clara:

```bash
NEWIP=<new-clara-ip>
age -d -i ~/.config/age/keys.txt ~/mynix/secrets/clara-docker-config.json.age \
  | ssh cloudgenius@$NEWIP 'umask 077; mkdir -p ~/.docker && cat > ~/.docker/config.json && chmod 600 ~/.docker/config.json'
```

Without this, containers using private-registry images (coursebook) will
fail to pull on the new clara.

### 5. Deploy keys for private repos

From your admin machine (surf):

```bash
NEWIP=<new-clara-ip>
for repo in clara-nginx clara-cloudflared authentik-clara pangolin-clara; do
  key=${repo//-/_}_deploy_key
  ssh cloudgenius@$NEWIP "ssh-keygen -t ed25519 -f ~/.ssh/$key -N '' -C 'clara-$repo-deploy'"
  PUB=$(ssh cloudgenius@$NEWIP "cat ~/.ssh/$key.pub")
  gh api -X POST /repos/lvnilesh/$repo/keys \
    -f "title=clara-$repo-deploy" -f "key=$PUB" -F "read_only=true"
  ssh cloudgenius@$NEWIP "cat >> ~/.ssh/config" <<EOF2
Host github-$repo
  HostName github.com
  IdentityFile ~/.ssh/$key
  IdentitiesOnly yes
EOF2
  # test
  ssh cloudgenius@$NEWIP "ssh -T git@github-$repo"
done
```

(Repositories under `beacloudgenius` — same command but different owner slug.)

### 4. Rsync stateful data from old clara

```bash
OLDIP=<old-clara-ip>
NEWIP=<new-clara-ip>

# Authentik state (postgres + media)
ssh cloudgenius@$OLDIP 'sudo systemctl stop docker' || true  # optional: pause writes
rsync -avP cloudgenius@$OLDIP:src/authentik-clara/data     cloudgenius@$NEWIP:src/authentik-clara/
rsync -avP cloudgenius@$OLDIP:src/authentik-clara/database cloudgenius@$NEWIP:src/authentik-clara/
rsync -avP cloudgenius@$OLDIP:src/authentik-clara/certs    cloudgenius@$NEWIP:src/authentik-clara/

# Pangolin state (sqlite + traefik certs)
rsync -avP cloudgenius@$OLDIP:src/pangolin-clara/config cloudgenius@$NEWIP:src/pangolin-clara/

# App containers (adjust for what's on your clara)
rsync -avP cloudgenius@$OLDIP:src/multistream-2026/data cloudgenius@$NEWIP:src/multistream-2026/
# etc.
```

Set container-user ownership:

```bash
ssh cloudgenius@$NEWIP 'sudo chown -R 1000:1000 ~/src/authentik-clara/{data,certs}'
ssh cloudgenius@$NEWIP 'sudo chown -R 70:70 ~/src/authentik-clara/database'
```

### 6. Trigger workflow deploys

```bash
for repo in clara-cloudflared clara-nginx authentik-clara pangolin-clara; do
  gh workflow run deploy.yml -R lvnilesh/$repo  # or beacloudgenius/ for clara-nginx
done
```

Watch runs:
```bash
gh run watch -R lvnilesh/clara-cloudflared
```

### 7. Update DNS

Only two hostnames actually pointing at clara's IP directly:

```bash
# grey cloud (direct A record for gerbil WireGuard UDP)
gh api -X PUT /zones/<ZONE_ID>/dns_records/<clara.cloudgeni.us record ID> ...
# proxied hostnames (auth.cloudgeni.us, pangolin.cloudgeni.us, etc.) are
# CNAME'd to the CF tunnel — no DNS change needed (tunnel routes to new VM
# once cloudflared runs there).
```

### 8. Open cloud firewall

Whatever your new cloud's mechanism:

| Proto | Port | From | Purpose |
|---|---|---|---|
| TCP | 22 | your IPs (or 0.0.0.0/0 if you must) | SSH |
| TCP | 80 | 0.0.0.0/0 | HTTP (redirect + ACME if needed) |
| TCP | 443 | 0.0.0.0/0 | HTTPS |
| UDP | 51820 | 0.0.0.0/0 | Gerbil WireGuard tunnel server |
| UDP | 21820 | 0.0.0.0/0 | Gerbil WireGuard client relay |

For Azure: NSG → Networking → Inbound rules.
For Hetzner: Cloud Console → firewall.
For DigitalOcean: cloud firewall or ufw.

### 9. Shut down old clara

Verify new clara is answering:
```bash
curl -sI https://auth.cloudgeni.us/
curl -sI https://pangolin.cloudgeni.us/
```

Then power off the old VM. Snapshot for safety before delete.

## Rollback

CF Tunnel is still on the old VM's `cloudflared` too until you stop it there.
If new clara has an issue, `sudo systemctl stop cloudflared` on new + `start`
on old flips traffic back within seconds.

## What state is NOT in git and MUST be preserved

| Item | Location | Backup |
|---|---|---|
| CF Tunnel credentials | `/etc/cloudflared/<tunnel-id>.json` | `~/mynix/secrets/clara-cf-tunnel-creds.age` |
| CF Origin cert | `/etc/nginx/ssl/cloudgeni-origin.{crt,key}` | `~/mynix/secrets/clara-cf-origin.{crt,key}.age` |
| Authentik postgres | `~/src/authentik-clara/database/` | rsync from old |
| Pangolin sqlite | `~/src/pangolin-clara/config/db/` | rsync from old |
| Container app data | `~/src/*/data/` | rsync from old |

Everything else regenerates from git + workflows.
