variable "hcloud_token" {
  description = "Hetzner Cloud API token (HCLOUD_TOKEN in .env)"
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
  description = "Default Linux username created on all servers (overridable per-server in var.servers)"
  type        = string
  default     = "ikaros"
}

variable "user_password" {
  description = "Plaintext sudo password for the server user (var.username). Terraform derives a bcrypt hash for cloud-init."
  type        = string
  sensitive   = true
}

variable "server_location" {
  description = "Hetzner Cloud datacenter location (e.g. fsn1, nbg1, hel1, ash, hil)"
  type        = string
  default     = "fsn1"
}

variable "server_type" {
  description = "Hetzner Cloud server type (e.g. cx22, cx32, cpx11)"
  type        = string
  default     = "cx23"
}

variable "servers" {
  description = <<-EOT
    Map of server name → config.  Each key becomes the hcloud_server name
    and Tailscale hostname.
    role:        Hetzner label and Ansible inventory group name.
    server_type: Override the default var.server_type for this server (optional).
  EOT
  type = map(object({
    role        = string
    server_type = optional(string)
    username    = optional(string)
  }))
  default = {
    "dev-env" = { role = "dev" }
  }
}
