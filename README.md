# dev-env — Cloud Dev Environment Bootstrap

Terraform + Ansible bootstrap for a Hetzner Cloud dev server running
Ubuntu 24.04 LTS.  All connectivity via [Tailscale](https://tailscale.com/).

One `terraform apply` + one `ansible-playbook` gives you a fully configured
remote dev machine with Docker, Node.js, code-server, Caddy, CoreDNS,
Claude Code, Playwright, and more — accessible over Tailscale SSH.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Generating a hashed password](#2-generating-a-hashed-password)
3. [Filling in terraform.tfvars](#3-filling-in-terraformtfvars)
4. [Terraform init / apply](#4-terraform-init--apply)
5. [Waiting for the server to join the tailnet](#5-waiting-for-the-server-to-join-the-tailnet)
6. [Generating the Ansible inventory](#6-generating-the-ansible-inventory)
7. [Running the Ansible playbook](#7-running-the-ansible-playbook)
8. [SSH into the server](#8-ssh-into-the-server)
9. [Tearing down](#9-tearing-down)

---

## 1. Prerequisites

### Accounts

| Service | What you need |
|---------|---------------|
| **Hetzner Cloud** | A project + Read/Write API token |
| **Tailscale** | An account + tailnet with MagicDNS enabled |

### Local tools

Install these before starting:

```bash
# macOS (Homebrew)
brew install terraform ansible tailscale pre-commit tflint
brew install --cask tailscale  # or use the Mac app

# Debian/Ubuntu
sudo apt-get install -y terraform ansible

# All platforms
pip install pre-commit ansible-lint yamllint
```

Verify versions:

```bash
terraform version        # ~> 1.x
ansible --version        # >= 2.15
tailscale version
pre-commit --version
```

### Tailscale auth key

You need a pre-authorized, reusable key tagged `tag:dev-env`:

1. Go to <https://login.tailscale.com/admin/settings/keys>
2. Click **Generate auth key**
3. Set:
   - **Reusable**: on
   - **Ephemeral**: off
   - **Pre-authorized**: on
   - **Tags**: `tag:dev-env`
4. Copy the key — it starts with `tskey-auth-`.

> **Note**: Tag owners for `tag:dev-env` must be configured first.
> See `tailscale/acl.hujson` and apply it at
> <https://login.tailscale.com/admin/acls>.

---

## 2. Generating a hashed password

### Hashed password (for sudo)

```bash
# Install mkpasswd if needed:
#   apt-get install whois   OR   brew install --cask whois
mkpasswd -m sha-512
```

Enter your chosen sudo password when prompted. Copy the full output
(starts with `$6$`).

---

## 3. Filling in terraform.tfvars

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# terraform.tfvars is gitignored — it never gets committed.
$EDITOR terraform/terraform.tfvars
```

Fill in:

| Variable | Where to get it |
|----------|----------------|
| `hcloud_token` | Hetzner Cloud Console → Security → API Tokens |
| `tailscale_auth_key` | Step 1 above |
| `ikaros_hashed_password` | Step 2 above |

---

## 4. Terraform init / apply

```bash
cd terraform/

terraform init
terraform validate
terraform plan
terraform apply
```

`apply` typically takes ~30 seconds.  The server boots and begins executing
cloud-init in the background.

---

## 5. Waiting for the server to join the tailnet

Cloud-init installs Tailscale and runs `tailscale up` on first boot, which
takes roughly 30-60 seconds after the server starts.

Poll until the server appears:

```bash
# Watch tailscale status until the new host appears
watch -n5 tailscale status
```

You should see something like:

```
dev-env   100.x.y.z   linux   active; ...
```

Once `dev-env` is listed, the server is on the tailnet and reachable.

---

## 6. Generating the Ansible inventory

```bash
# From the repo root:
bash scripts/gen-inventory.sh
```

This reads `tailscale status --json` and writes
`ansible/inventory/hosts.yml`.  Re-run after any `terraform apply` that
changes server topology.

---

## 7. Running the Ansible playbook

```bash
cd ansible/

# Secrets are decrypted automatically from Ansible Vault.
# Ensure ~/.ansible_vault_pass exists (see CLAUDE.md for details).
ansible-playbook playbooks/site.yml
```

The sudo password is supplied via Ansible Vault (`inventory/group_vars/all/vault.yml`),
not via CLI prompt.  NOPASSWD is intentionally not used — see CLAUDE.md for
rationale.

A fully converged host should produce **zero changes** on re-run:

```bash
ansible-playbook playbooks/site.yml
# Expected: ok=N  changed=0  failed=0
```

---

## 8. SSH into the server

```bash
# Tailscale MagicDNS — works if MagicDNS is enabled on your tailnet.
ssh ikaros@dev-env

# Alternatively, use the full MagicDNS name:
ssh ikaros@dev-env.<your-tailnet>.ts.net

# Or Tailscale SSH (no key needed, uses tailnet identity):
tailscale ssh ikaros@dev-env
```

---

## 9. Tearing down

```bash
cd terraform/
terraform destroy
```

This removes the Hetzner server and firewall.  The Tailscale device entry
is **not** ephemeral — remove it manually at
<https://login.tailscale.com/admin/machines> after destroying the server.

---

## Pre-commit hooks

```bash
# Install hooks into .git/hooks/
pre-commit install

# Run against all files manually
pre-commit run --all-files
```

Hooks: `terraform fmt`, `tflint`, `ansible-lint`, `yamllint`, `gitleaks`.

---

## Secret management

**Terraform** secrets are passed via `terraform/terraform.tfvars` (gitignored)
or `TF_VAR_*` environment variables.  Do not commit `terraform.tfvars`.

**Ansible** secrets (`ansible_become_pass`, `caddy_cf_api_token`) are stored in
Ansible Vault-encrypted files under `ansible/inventory/group_vars/`.  The vault
password is read from `~/.ansible_vault_pass` (configured in `ansible/ansible.cfg`).

To edit vault secrets:
```bash
cd ansible/
ansible-vault edit inventory/group_vars/all/vault.yml   # sudo password
ansible-vault edit inventory/group_vars/dev/vault.yml    # Cloudflare API token
```
