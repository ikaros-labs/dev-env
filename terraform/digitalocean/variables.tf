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

variable "user_password" {
  description = "Plaintext sudo password for the server user (var.username). Terraform derives a bcrypt hash for cloud-init."
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

variable "do_project_id" {
  description = "DigitalOcean project ID to assign all droplets to (optional). Find at https://cloud.digitalocean.com/projects"
  type        = string
  default     = null
}

variable "firewall_name" {
  description = "Name for the DigitalOcean Cloud Firewall resource"
  type        = string
  default     = "main-firewall"
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
