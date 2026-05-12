output "servers" {
  description = <<-EOT
    Map of server name → provisioned info (for reference).
    Ansible inventory is generated from the server_usernames output by gen-inventory.sh.
  EOT
  value = {
    for name, droplet in digitalocean_droplet.servers : name => {
      do_ipv4  = droplet.ipv4_address
      role     = var.servers[name].role
      username = local.server_username[name]
    }
  }
}

output "server_usernames" {
  description = "Map of server name → Linux username, consumed by gen-inventory.sh"
  value       = local.server_username
}

output "firewall_id" {
  description = "ID of the main DigitalOcean firewall"
  value       = digitalocean_firewall.main.id
}
