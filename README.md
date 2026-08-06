# clara-bootstrap

One-command provisioning of a fresh Ubuntu 24.04 VM into a "clara-ready" state,
suitable for hosting the homelab stack (Authentik, Pangolin, nginx, ghost,
coursebook, multistream, …).

## Quickstart

On a fresh Ubuntu 24.04 VM (as root or via sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/lvnilesh/clara-bootstrap/main/bootstrap.sh | sudo bash
```

That's it. About 5 minutes. The bootstrap also creates a persistent 2 GiB
swapfile with `vm.swappiness=10`. Then follow [MIGRATION.md](./MIGRATION.md) for
the deploy-key + rsync steps.

## Declarative Azure state

[`infrastructure/desired-state.json`](./infrastructure/desired-state.json) owns
the existing production Clara VM size and host memory policy:

- Azure SKU: `Standard_B2ms` (2 vCPU, 8 GiB RAM)
- swapfile: `/swapfile`, 2 GiB
- swappiness: `10`

The `Reconcile Clara infrastructure` GitHub Actions workflow runs on the
separate `actions-runner` VM. A push that changes the desired state, bootstrap,
or host-policy scripts makes it:

1. log in to Azure and resize Clara only when the SKU differs;
2. wait for Clara to return after the required deallocate/start cycle;
3. reconcile swap and Tailscale/OpenSSH policy over SSH;
4. verify the Azure SKU, active swap size, and swappiness.

The workflow requires two repository secrets:

- `AZURE_CREDENTIALS`: a service principal scoped to Clara's resource group
  with the `Virtual Machine Contributor` role;
- `CLARA_SSH_PRIVATE_KEY`: the private half matching
  [`keys/clara-bootstrap-actions.pub`](./keys/clara-bootstrap-actions.pub).

Recovery copies are encrypted in the `mynix` repository as
`secrets/clara-azure-credentials.json.age` and
`secrets/clara-bootstrap-actions-ssh.age`. Never commit either plaintext.

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

A small bootstrap and desired-state repository, deliberately without a large
configuration-management framework. Everything on Clara is driven by GitHub
Actions workflows here and in per-service repos
([clara-nginx](https://github.com/beacloudgenius/clara-nginx),
[clara-cloudflared](https://github.com/lvnilesh/clara-cloudflared),
[authentik-clara](https://github.com/lvnilesh/authentik-clara),
[pangolin-clara](https://github.com/lvnilesh/pangolin-clara), etc.). This
repo gets the OS ready and keeps the existing Azure VM size and core host policy
converged.

## Not in scope

- First-time cloud VM creation (use the `mynix` forklift script).
- Firewall rules (cloud-specific — see MIGRATION.md).
- Service deploy keys, service secrets, and DNS are handled by their respective
  repositories.

## Cloud portability

Works on any Ubuntu 24.04 image from Azure, Hetzner, DigitalOcean, Linode,
Vultr, EC2, or a bare-metal server. No cloud-specific hooks.
