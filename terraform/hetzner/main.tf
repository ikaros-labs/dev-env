locals {
  # All Hetzner resources receive these labels for cost attribution and
  # change-management traceability.
  common_labels = {
    "managed-by" = "terraform"
  }

  # Effective username per server: per-server override wins, then global default.
  server_username = {
    for name, cfg in var.servers : name => coalesce(cfg.username, var.username)
  }
}

# ---------------------------------------------------------------------------
# SSH key — registered solely to suppress Hetzner new-server credential emails.
# Generated on the fly; the private key is never used. cloud-init removes
# /root/.ssh on first boot, so the key is gone before any service starts.
# ---------------------------------------------------------------------------
resource "tls_private_key" "placeholder" {
  algorithm = "ED25519"
}

resource "hcloud_ssh_key" "placeholder" {
  name       = "hetzner-email-suppressor"
  public_key = tls_private_key.placeholder.public_key_openssh
  labels     = local.common_labels
}

# ---------------------------------------------------------------------------
# Firewall — deny all inbound traffic
# ---------------------------------------------------------------------------
# Hetzner Cloud firewalls are default-deny for inbound when no rules are
# defined, so an empty rule set is the correct way to block all inbound.
# Tailscale uses NAT traversal / DERP relays for outbound-initiated tunnels
# and therefore needs no inbound ports.
resource "hcloud_firewall" "main" {
  name   = "main-firewall"
  labels = merge(local.common_labels, { role = "firewall" })

  # Intentionally no rules — deny all inbound by design.
}

# ---------------------------------------------------------------------------
# Servers
# ---------------------------------------------------------------------------
resource "hcloud_server" "servers" {
  for_each = var.servers

  name        = each.key
  server_type = coalesce(each.value.server_type, var.server_type)
  image       = "ubuntu-24.04"
  location    = var.server_location

  backups = true

  firewall_ids = [hcloud_firewall.main.id]
  ssh_keys     = [hcloud_ssh_key.placeholder.id]

  user_data = sensitive(templatefile("${path.module}/../cloud-init.yaml.tftpl", {
    tailscale_auth_key   = var.tailscale_auth_key
    user_hashed_password = var.user_hashed_password
    username             = local.server_username[each.key]
  }))

  labels = merge(local.common_labels, { role = each.value.role })
}
