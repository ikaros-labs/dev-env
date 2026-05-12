output "servers" {
  description = <<-EOT
    Map of server name → provisioned info (for reference).
    Ansible inventory is generated from Tailscale status, not this output.
  EOT
  value = {
    for name, server in hcloud_server.servers : name => {
      hcloud_ipv4 = server.ipv4_address
      role        = var.servers[name].role
      username    = local.server_username[name]
    }
  }
}

output "server_usernames" {
  description = "Map of server name → Linux username, consumed by gen-inventory.sh"
  value       = local.server_username
}

output "firewall_id" {
  description = "ID of the main Hetzner firewall"
  value       = hcloud_firewall.main.id
}
