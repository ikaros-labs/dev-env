locals {
  # All DigitalOcean resources receive these tags for cost attribution and
  # change-management traceability.
  # DO tags are flat strings — use "key:value" convention.
  common_tags = ["managed-by:terraform"]

  # Effective username per droplet: per-server override wins, then global default.
  server_username = {
    for name, cfg in var.servers : name => coalesce(cfg.username, var.username)
  }
}

# ---------------------------------------------------------------------------
# VPC — isolates all droplets on a dedicated private network segment.
# Droplets communicate privately via their VPC IP; the cloud firewall still
# controls what enters from the internet (deny-all inbound).
# ---------------------------------------------------------------------------
resource "digitalocean_vpc" "main" {
  name     = "dev-env-vpc"
  region   = var.region
  ip_range = var.vpc_cidr
}

# ---------------------------------------------------------------------------
# SSH key — registered solely to suppress DigitalOcean new-droplet credential
# emails (DO sends a root password email unless at least one SSH key is
# attached at creation time).  Generated on the fly; the private key is never
# used.  cloud-init removes /root/.ssh on first boot, so the key is gone
# before any service starts.
# ---------------------------------------------------------------------------
resource "tls_private_key" "placeholder" {
  algorithm = "ED25519"
}

resource "digitalocean_ssh_key" "placeholder" {
  name       = "do-email-suppressor"
  public_key = tls_private_key.placeholder.public_key_openssh
}

# ---------------------------------------------------------------------------
# Project assignment (optional)
# ---------------------------------------------------------------------------
resource "digitalocean_project_resources" "servers" {
  count   = var.do_project_id != null ? 1 : 0
  project = var.do_project_id
  resources = [for d in digitalocean_droplet.servers : d.urn]
}

# ---------------------------------------------------------------------------
# Firewall — deny all inbound, allow all outbound
# ---------------------------------------------------------------------------
# DigitalOcean Cloud Firewalls are ALLOW-LIST based (unlike Hetzner which is
# default-deny inbound with no outbound filtering).
#   - Inbound: no rules defined = deny all inbound.
#   - Outbound: explicit allow-all rules are required — omitting them would
#     block apt, the Tailscale install, and Tailscale DERP on first boot.
# Firewall association is via droplet_ids here, not on the droplet resource.
resource "digitalocean_firewall" "main" {
  name        = "main-firewall"
  droplet_ids = [for d in digitalocean_droplet.servers : d.id]

  # Intentionally no inbound_rule blocks — deny all inbound by design.

  outbound_rule {
    protocol              = "tcp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "all"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# ---------------------------------------------------------------------------
# Droplets
# ---------------------------------------------------------------------------
resource "digitalocean_droplet" "servers" {
  for_each = var.servers

  name   = each.key
  size   = coalesce(each.value.droplet_size, var.droplet_size)
  image  = "ubuntu-24-04-x64"
  region = var.region

  vpc_uuid = digitalocean_vpc.main.id

  backups    = true
  monitoring = true

  # fingerprint is required by the DO provider (not .id as in Hetzner).
  ssh_keys = [digitalocean_ssh_key.placeholder.fingerprint]

  user_data = sensitive(templatefile("${path.module}/../cloud-init.yaml.tftpl", {
    tailscale_auth_key   = var.tailscale_auth_key
    user_hashed_password = bcrypt(var.user_password)
    username             = local.server_username[each.key]
  }))

  tags = concat(local.common_tags, ["role:${each.value.role}"])

  # cloud-init runs once on first boot only; in-place user_data updates have
  # no effect. Use `terraform apply -replace=digitalocean_droplet.servers[\"<name>\"]`
  # to intentionally reprovision a droplet with updated user_data.
  lifecycle {
    ignore_changes = [user_data]
  }
}
