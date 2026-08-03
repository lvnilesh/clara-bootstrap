# clara-bootstrap

One-command provisioning of a fresh Ubuntu 24.04 VM into a "clara-ready" state,
suitable for hosting the homelab stack (Authentik, Pangolin, nginx, ghost,
coursebook, multistream, …).

## Quickstart

On a fresh Ubuntu 24.04 VM (as root or via sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | sudo bash
```

That's it. About 5 minutes. Then follow [MIGRATION.md](./MIGRATION.md) for
the deploy-key + rsync steps.

### Recommended: run from cloud-init before first SSH

Clara renames the default cloud user (`azureuser`, `ubuntu`, …) to `cloudgenius`
via `usermod -l`. That will **fail** if the default user is currently logged
in — i.e. if you SSH'd in as `azureuser` and are running the script under
sudo. The clean fix is to invoke the script from cloud-init before any
interactive login happens.

**Use the `runcmd:` list form, not the string form.** cloud-init runs the
string form under `dash`, which silently ignores `#!/usr/bin/env bash`
shebangs and blows up on `set -o pipefail` in the wrapper — the actual
`bootstrap.sh` still runs under bash, but the wrapper pipe you write in
cloud-init may not:

```yaml
#cloud-config
runcmd:
  - [bash, -c, "curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | bash"]
```

Or, if you need to pass env vars:

```yaml
#cloud-config
runcmd:
  - [bash, -c, "export CLARA_HOSTNAME=clara CLARA_IGNOREIP='192.168.1.0/24 73.221.218.159/32'; curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | bash"]
```

### Alternative: out-of-band execution after boot

If cloud-init isn't an option, use your cloud's OOB command runner instead
of SSH'ing in first. Examples:

```bash
# Azure
az vm run-command invoke -g <RG> -n <VM> --command-id RunShellScript \
  --scripts "curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | bash"

# Hetzner (via API or hcloud CLI in console mode)
# DigitalOcean: droplet console → paste command
```

### Escape hatch (drops your session)

Only use if you're stuck in an SSH session and have console/OOB fallback:

```bash
CLARA_ALLOW_KILL_USER_1000=1 sudo -E bash bootstrap.sh
```

The script will kill uid 1000's processes (including your SSH login) then
rename. Re-connect as `cloudgenius@…` via the cloud console.

## What this repo is

A single bash script + runbook, deliberately no fancy Ansible/Terraform. The
philosophy: everything on clara is driven by GitHub Actions workflows on
per-service repos ([clara-nginx](https://github.com/beacloudgenius/clara-nginx),
[clara-cloudflared](https://github.com/lvnilesh/clara-cloudflared),
[authentik-clara](https://github.com/lvnilesh/authentik-clara),
[pangolin-clara](https://github.com/lvnilesh/pangolin-clara), etc.). This
repo just gets the OS to the point where those workflows can take over.

## Not in scope

- Cloud VM provisioning (use each cloud's own UI/CLI).
- Firewall rules (cloud-specific — see MIGRATION.md).
- Deploy keys, GH Secrets, DNS — handled by their respective repos.

## Cloud portability

Works on any Ubuntu 24.04 image from Azure, Hetzner, DigitalOcean, Linode,
Vultr, EC2, or a bare-metal server. No cloud-specific hooks.
