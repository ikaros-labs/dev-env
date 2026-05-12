# CLAUDE.md — IaC Agent Reference

This file is the authoritative reference for any agent (or human) working in
this repository.  **Read it before making changes.**  When a rule changes,
update this file in the same commit.

---

## Project status: experimental

This project is in an **experimental / bootstrapping phase**.  Stability is
not guaranteed and is not the goal right now.

- **Breaking changes are fine** — don't hesitate to make them.
- **Resources can and should be recreated from scratch** when needed.
  `terraform destroy && terraform apply` is a normal workflow here, not a
  last resort.
- This repo provisions a **dev environment only** — no production workloads.
- **Server state is disposable** — if something is easier to fix by
  reprovisioning than by debugging in place, reprovision.

This note should be removed (or replaced with a phased rollout policy) once
the first real workload is deployed and a human is relying on the
infrastructure.

---

## Table of contents

1. [Bootstrap flow](#bootstrap-flow)
2. [Rules and rationale](#rules-and-rationale)
3. [Conventions](#conventions)
4. [Known-incomplete areas](#known-incomplete-areas)
5. [Future work (out of scope for initial pass)](#future-work-out-of-scope-for-initial-pass)
6. [Exceptions log](#exceptions-log)

---

## Bootstrap flow

The "chicken-and-egg" problem: a new server has no public SSH access (the
cloud firewall denies all inbound), so Ansible cannot reach it the
traditional way.  This is solved by Tailscale + cloud-init:

```
Terraform apply  (terraform/hetzner/ or terraform/digitalocean/)
  │
  ├─► hcloud_firewall / digitalocean_firewall  (deny all inbound)
  │
  └─► hcloud_server.servers / digitalocean_droplet.servers  (for_each over var.servers)
        │  Creates: dev-env (role=dev)
        │  user_data = templatefile(../cloud-init.yaml.tftpl, {
        │    tailscale_auth_key, user_hashed_password, username
        │  })
        │
        ▼ (server boots, cloud-init runs ~30–60 s)
        │
        ├─► Create user (var.username, sudo group, hashed password)
        ├─► Write /etc/ssh/sshd_config.d/99-hardening.conf
        ├─► Lock root password (passwd -l root)
        ├─► Install Tailscale via apt repository
        ├─► tailscale up --ssh --advertise-tags=tag:dev-env --auth-key=...
        └─► systemctl restart ssh

        Server joins tailnet via NAT traversal / DERP.
        No inbound port needed.

scripts/gen-inventory.sh [--tf-dir terraform/hetzner|terraform/digitalocean]
  │
  ├─► terraform output -json server_usernames (if state available)
  └─► tailscale status --json
        Filter peers with tag:dev-env.
        Map tag:dev-env → group "dev-env".
        ansible_host = Tailscale IP (collision-proof, no MagicDNS dependency).
        ansible_user = per-server username from Terraform output.
        Writes ansible/hosts.yml.

Ansible (from a machine on the same tailnet)
  │
  └─► ansible-playbook setup.yml
        Connects via Tailscale IP as the configured user (ansible_user).
        All servers:  common, unattended_upgrades, docker, github_cli,
                      node_tooling, zsh_config.
        Dev servers:  claude_code, playwright, ansible_tool, terraform,
                      caddy, code_server, coredns.
```

**Scope boundary** — cloud-init owns *identity and access* only.  Do not use
cloud-init for package installation, service configuration, or anything that
needs to be re-runnable.  Those belong in Ansible roles.

---

## Rules and rationale

### User: configurable (default: ikaros)

**Rule**: All managed servers have a non-root user in the `sudo` group.
The username is set via `var.username` (global default) or per-server via
`var.servers[name].username`.  Default: `ikaros`.

**Why**: Running application workloads and Ansible as root is a security
anti-pattern.  A named, non-root user provides an audit trail and limits
blast radius.  Making the username configurable allows each user to set
their own preferred name.

**Where**: `terraform/hetzner/variables.tf` or `terraform/digitalocean/variables.tf` — `username` variable;
`terraform/cloud-init.yaml.tftpl` — `users:` block.

**Tailscale ACL dependency**: The SSH rule in the Tailscale ACL policy lists
allowed usernames.  When changing the username, update the `"users"` array
and apply it at <https://login.tailscale.com/admin/acls>.

---

### SSH authentication: Tailscale SSH only

**Rule**: All SSH access goes through Tailscale SSH (`tailscale up --ssh`).
No SSH public keys are placed in `authorized_keys`.  Password authentication
over SSH is disabled.  The Tailscale ACL SSH rule (<https://login.tailscale.com/admin/acls>)
must list any usernames used across servers.

**Why**: The cloud firewall blocks all inbound traffic, so standard SSH
port 22 is unreachable from the internet regardless.  Tailscale SSH
authenticates using Tailscale identity (WireGuard + ACL policy), making a
separate `authorized_keys` file redundant.  Removing the SSH public key
eliminates one secret to generate, store, and rotate.

**Where**: `tailscale up --ssh` in `terraform/cloud-init.yaml.tftpl` —
`runcmd:` block.  Password auth is disabled by
`/etc/ssh/sshd_config.d/99-hardening.conf` (`PasswordAuthentication no`).

---

### Sudo requires a password (no NOPASSWD)

**Rule**: The configured user can sudo but must provide a password.
`NOPASSWD` must not be used.

**Why**: If an attacker gains code execution as the server user (e.g., via a
compromised service), they cannot silently escalate to root without knowing
the password.  The sudo password is a meaningful second factor.

**Implication**: The sudo password is stored in an Ansible Vault-encrypted
file (`vault.yml`) and supplied automatically.  The vault
password file (`~/.ansible_vault_pass`) is configured in `ansible.cfg`.

**Where**: The sudo group membership in cloud-init inherits Ubuntu's default
`%sudo ALL=(ALL:ALL) ALL` rule (password required).  The hashed password is
set via `passwd:` in cloud-init.

---

### Hashed password supplied as a sensitive Terraform variable

**Rule**: The server user's sudo password is provided as a SHA-512 hash
(e.g. from `mkpasswd -m sha-512`), never as plaintext.

**Why**: Terraform state, plan output, and logs may be visible to other
tools.  A hash limits exposure.  Marked `sensitive = true` in the variable
definition.

**Where**: `terraform/{hetzner,digitalocean}/variables.tf` — `user_hashed_password` variable;
`terraform/{hetzner,digitalocean}/main.tf` — `sensitive(templatefile(...))` wrapper.

---

### SSH hardening drop-in

**Rule**: Every server gets `/etc/ssh/sshd_config.d/99-hardening.conf` with:
```
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
```

**Why**: Defence in depth.  Even if a future package or user accidentally
unlocks password authentication system-wide, this drop-in wins
(alphabetically last in `sshd_config.d/`).

**Where**: `terraform/cloud-init.yaml.tftpl`.

---

### Root password locked

**Rule**: `passwd -l root` runs during cloud-init.

**Why**: Belt-and-suspenders with `PermitRootLogin no`.  A locked password
prevents local console su/sudo to root with a blank password if sshd is
somehow bypassed.

**Where**: `terraform/cloud-init.yaml.tftpl` — `runcmd:` block.

---

### Cloud firewall: deny all inbound

**Rule**: Every server is attached to a cloud firewall with no inbound rules
(= deny all).  No host-level firewall (UFW/nftables) is used.

**Why**: Cloud firewalls are enforced at the hypervisor/network level before
traffic reaches the VM — simpler and more robust than a host-level firewall.
Tailscale traffic arrives through `tailscale0` (a WireGuard interface) which
is already inside the VM and bypasses the cloud firewall entirely.  A
host-level firewall would duplicate this logic unnecessarily.

**Provider-specific behaviour**:
- **Hetzner**: default-deny inbound when no rules are defined; outbound is
  never filtered.  An empty `hcloud_firewall` resource is sufficient.
- **DigitalOcean**: firewalls are ALLOW-LIST based.  Inbound is denied by
  omitting `inbound_rule` blocks.  Outbound must be explicitly allowed (tcp,
  udp, icmp to `0.0.0.0/0`/`::/0`) — without these rules the droplet cannot
  reach apt, Tailscale install CDN, or DERP relays on first boot.

**Where**: `terraform/hetzner/main.tf` — `hcloud_firewall.main`;
`terraform/digitalocean/main.tf` — `digitalocean_firewall.main`.

---

### Tailscale for all connectivity

**Rule**: All SSH and service access goes through Tailscale.  No public
ports are opened.

**Why**: Tailscale provides mutual authentication (WireGuard + Tailscale
identity), encrypted transit, and NAT traversal without exposing any
listening port to the internet.

**Auth key spec**: Pre-authorized, reusable, tagged `tag:dev-env`.
- *Pre-authorized*: no manual approval step needed.
- *Reusable*: allows key reuse if additional servers are added.
  The key still expires at its configured TTL.
- *tag:dev-env*: applies the ACL policy configured at <https://login.tailscale.com/admin/acls>.
- *Not ephemeral*: device entries persist after server destruction and must
  be removed manually at <https://login.tailscale.com/admin/machines>.

**Where**: `terraform/cloud-init.yaml.tftpl` — `runcmd:` block (shared by all providers).

---

### Unattended security upgrades with auto-reboot

**Rule**: Every server runs `unattended-upgrades` with `Automatic-Reboot`
enabled and `Automatic-Reboot-Time "03:00"` (UTC).

**Why**: The default Ubuntu unattended-upgrades configuration never reboots,
which means kernel security patches are not applied until the next manual
reboot.  That defeats the purpose of unattended upgrades.

**Maintenance window**: 03:00–04:00 UTC (next apt run after 03:00).
`Automatic-Reboot-WithUsers "false"` means the server reboots even if
sessions are open — expected behaviour for server infrastructure.

**Where**: `ansible/roles/unattended_upgrades/`.

---

### Automated backups

**Rule**: `backups = true` on every server resource.

**Why**: Automated backups provide a point-in-time recovery option for ~20%
of the server cost.  Opt-out requires an explicit inline comment explaining
why.

**Where**: `terraform/hetzner/main.tf` — `hcloud_server.servers`;
`terraform/digitalocean/main.tf` — `digitalocean_droplet.servers`.

---

### Tagging / labelling every cloud resource

**Rule**: Every cloud resource gets a `managed-by` and `role` marker.

**Why**: Tags/labels enable resource queries and automation
(e.g. "list all servers with role=dev").  `managed-by=terraform` prevents
accidental manual changes going unnoticed.

**Provider-specific implementation**:

*Hetzner* — key-value labels map on every `hcloud_*` resource:
```hcl
labels = merge(local.common_labels, { role = "<role>" })
# local.common_labels = { "managed-by" = "terraform" }
```

*DigitalOcean* — flat string tags (DO does not support key-value labels):
```hcl
tags = concat(local.common_tags, ["role:<role>"])
# local.common_tags = ["managed-by:terraform"]
```

**Convention**:
| Key | Hetzner value | DO tag | Notes |
|-----|--------------|--------|-------|
| managed-by | `terraform` | `managed-by:terraform` | Always |
| role | `dev`, `firewall`, … | `role:dev`, … | Per-resource |

**Where**: `terraform/hetzner/main.tf` and `terraform/digitalocean/main.tf` — `locals` block + each resource.

---

### Ansible idempotency

**Rule**: Every Ansible role must be idempotent.  Re-running a playbook
against a converged host must produce zero changes.

**Why**: Non-idempotent roles make re-runs risky and prevent using playbook
runs as a convergence health check.

**How to verify**:
```bash
ansible-playbook playbooks/setup.yml
# Run twice; second run must show changed=0.
```

---

### Dynamic Ansible inventory from Tailscale status

**Rule**: The Ansible inventory (`ansible/inventory/hosts.yml`) is generated
from `tailscale status --json`.  It is gitignored and must never be
hand-maintained.

**Why**: Tailscale is the actual connectivity layer; it is the authoritative
source of truth for which servers are reachable and under what address.
Using Terraform outputs caused hostname drift when a Tailscale device was
renamed due to a name collision.

**How**: Run `scripts/gen-inventory.sh` after every `terraform apply` or
whenever the tailnet topology changes.  Requires `tailscale` in PATH and
that the machine running the script is on the same tailnet.  The script
also reads `terraform output -json server_usernames` to set `ansible_user`
per host (falls back to `$ANSIBLE_USER` or `ikaros` if Terraform state is
unavailable).

Pass `--tf-dir` to point at the active provider module:
```bash
bash scripts/gen-inventory.sh                                    # Hetzner (default)
bash scripts/gen-inventory.sh --tf-dir terraform/digitalocean   # DigitalOcean
```

**Inventory source**: Peers tagged `tag:dev-env`.
**Group mapping**: `tag:dev-env` → `dev-env`.
**`ansible_host`**: Tailscale IP (100.x.x.x) — no MagicDNS dependency.

**Provisioning**: Tag is advertised by `cloud-init.yaml.tftpl` via
`tailscale up --advertise-tags=tag:dev-env`.  To apply the tag to an
already-running server without reprovisioning, re-run `tailscale up` on the
server with `--advertise-tags=tag:dev-env`.

---

### Secret management

**Rule**: Secrets are managed differently depending on whether they are
consumed by Terraform or Ansible.

**Terraform secrets** are per-provider-module.  Each module has its own
`terraform.tfvars` (gitignored) or `TF_VAR_<name>` environment variables:
- Hetzner: `hcloud_token`, `tailscale_auth_key`, `user_hashed_password`
- DigitalOcean: `do_token`, `tailscale_auth_key`, `user_hashed_password`

`terraform.tfvars` must never be committed.  See `.gitignore`.

**Where**: `terraform/hetzner/terraform.tfvars.example` and
`terraform/digitalocean/terraform.tfvars.example` (templates, tracked).

**Ansible secrets** (`ansible_become_pass`, `caddy_cf_api_token`,
`anthropic_api_key`) are stored in a single Ansible Vault-encrypted file:
- `ansible/vault.yml` — all Ansible secrets.

The vault password is read from `~/.ansible_vault_pass` (gitignored), configured
via `vault_password_file` in `ansible/ansible.cfg`.

**To edit the vault file**:
```bash
cd ansible/
ansible-vault edit vault.yml
```

---

## Conventions

### File naming

| Area | Convention | Example |
|------|-----------|---------|
| Terraform | `snake_case.tf` | `main.tf`, `variables.tf` |
| Ansible roles | `snake_case` directory | `unattended_upgrades/` |
| Ansible tasks | `snake_case.yml` | `tasks/main.yml` |
| Cloud-init template | `<name>.yaml.tftpl` | `cloud-init.yaml.tftpl` |
| Scripts | `kebab-case.sh` | `gen-inventory.sh` |

### Role structure

Every Ansible role has at minimum:
```
roles/<name>/
  tasks/main.yml    # Required
  meta/main.yml     # Required (galaxy_info + dependencies)
  handlers/         # If the role has handlers
  files/            # Static files to copy
  templates/        # Jinja2 templates
```

### Terraform resource naming

- Use descriptive names, not generic ones.
- Single-instance resources: use a noun (`main` for the firewall).
- Multi-instance resources use `for_each`: `hcloud_server.servers` iterates
  over `var.servers`, keyed by server name (default: `dev-env`).

---

## Known-incomplete areas

### 1. Local Terraform state

**Status**: Terraform uses local `terraform.tfstate` files (default backend).
Each provider module has its own state: `terraform/hetzner/terraform.tfstate`
and `terraform/digitalocean/terraform.tfstate`.

**Risk**: Local state is lost if the operator's machine is lost; it cannot
be shared between contributors; it provides no locking, so concurrent
applies would corrupt it.

**Revisit when**: A second contributor joins or deploy access needs to be
shared.

**Action required**: Migrate to a remote backend (e.g. Hetzner Object
Storage with S3-compatible backend, or Terraform Cloud).  See the
[Terraform backend docs](https://developer.hashicorp.com/terraform/language/settings/backends/configuration).

---

### 2. Secret management

**Status**: Ansible secrets are stored in `ansible/vault.yml` (Ansible
Vault-encrypted).  Terraform
secrets are in a gitignored `terraform.tfvars` file or environment variables.
Terraform state may still contain sensitive values.

**Risk**: Terraform state can hold sensitive values even when variables are
marked `sensitive`.

**Revisit when**: Adding a second contributor, or setting up any form of
CI/CD pipeline.

**Action required**: Consider a secrets backend for Terraform state
encryption — options include HashiCorp Vault, AWS Secrets Manager, Infisical,
or 1Password Secrets Automation.

---

## Future work (out of scope for initial pass)

These are deliberately deferred.  When tackling one, create a plan, update
this file, and remove the item from this list.

| Item | Notes |
|------|-------|
| Remote Terraform state backend | Blocker for second contributor |
| Secret management | Terraform-side secrets manager integration |
| Host-level firewall (UFW/nftables) | Not needed while cloud firewall is sufficient |
| Time sync configuration | Ubuntu 24.04 ships with systemd-timesyncd (good defaults) |
| CI/CD | GitHub Actions / Gitea Actions for plan + apply |
| Stale Tailscale device cleanup | Auth keys are intentionally non-ephemeral. Recreating servers leaves orphaned device entries in the tailnet. Fix: `scripts/cleanup-tailnet.sh` using the Tailscale management API to delete stale `tag:dev-env` devices. Needs a Tailscale OAuth API key (separate from the auth key). |

---

## Exceptions log

Any deviation from the rules above must be recorded here with: date, file,
line, rule deviated from, reason.

| Date | File:line | Rule | Reason |
|------|-----------|------|--------|
| 2026-04-29 | `terraform/hetzner/main.tf` | SSH authentication: Tailscale SSH only | `hcloud_ssh_key.placeholder` registered in Hetzner solely to suppress new-server credential emails. Key pair is generated on the fly via `tls_private_key`; the private key is never used. `cloud-init` removes `/root/.ssh` on first boot before any service starts. |
| 2026-05-12 | `terraform/digitalocean/main.tf` | SSH authentication: Tailscale SSH only | `digitalocean_ssh_key.placeholder` registered in DigitalOcean solely to suppress new-droplet credential emails (DO emails a root password when no SSH key is attached). Same pattern as Hetzner: key pair generated on the fly, private key never used, `cloud-init` removes `/root/.ssh` on first boot. |
