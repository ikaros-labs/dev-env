variable "hcloud_token" {
  description = "Hetzner Cloud API token (set via TF_VAR_hcloud_token or terraform.tfvars)"
  type        = string
  sensitive   = true
}

variable "tailscale_auth_key" {
  description = <<-EOT
    Tailscale pre-authorized ephemeral auth key tagged with tag:server.
    Generate at https://login.tailscale.com/admin/settings/keys
    (Reusable: on, Ephemeral: on, Pre-authorized: on, Tags: tag:server).
  EOT
  type        = string
  sensitive   = true
}

variable "ikaros_hashed_password" {
  description = <<-EOT
    SHA-512 hashed password for the ikaros user.
    Generate with: mkpasswd -m sha-512
    Required for sudo (NOPASSWD is intentionally not used).
  EOT
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "Environment label applied to all Hetzner resources"
  type        = string
  default     = "dev"
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
    role:        Hetzner label, Ansible inventory group, and Tailscale role tag
                 (advertised as tag:<role> alongside tag:server).
    server_type: Override the default var.server_type for this server (optional).
  EOT
  type = map(object({
    role        = string
    server_type = optional(string)
  }))
  default = {
    "dev-env" = { role = "dev" }
  }
}
