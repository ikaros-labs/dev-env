variable "do_token" {
  description = "DigitalOcean API token (DO_TOKEN in .env)"
  type        = string
  sensitive   = true
}

variable "tailscale_auth_key" {
  description = <<-EOT
    Tailscale pre-authorized auth key tagged with tag:dev-env.
    Generate at https://login.tailscale.com/admin/settings/keys
    (Reusable: on, Ephemeral: off, Pre-authorized: on, Tags: tag:dev-env).
  EOT
  type        = string
  sensitive   = true
}

variable "username" {
  description = "Default Linux username created on all droplets (overridable per-server in var.servers)"
  type        = string
  default     = "ikaros"
}

variable "user_hashed_password" {
  description = <<-EOT
    SHA-512 hashed password for the server user (var.username).
    Generate with: mkpasswd -m sha-512
    Required for sudo (NOPASSWD is intentionally not used).
  EOT
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean datacenter region slug (e.g. fra1, ams3, nyc3, lon1, sgp1, sfo3)"
  type        = string
  default     = "fra1"
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug (e.g. s-2vcpu-4gb, s-4vcpu-8gb)"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "servers" {
  description = <<-EOT
    Map of server name → config.  Each key becomes the Droplet name
    and Tailscale hostname.
    role:         DO tag and Ansible inventory group name.
    droplet_size: Override the default var.droplet_size for this droplet (optional).
    username:     Override the default var.username for this droplet (optional).
  EOT
  type = map(object({
    role         = string
    droplet_size = optional(string)
    username     = optional(string)
  }))
  default = {
    "dev-env" = { role = "dev" }
  }
}
