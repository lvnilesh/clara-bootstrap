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
