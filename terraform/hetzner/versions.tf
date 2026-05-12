terraform {
  required_version = "~> 1.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Local state — intentionally simple for now.
  # See CLAUDE.md "Known-incomplete areas" before adding a second
  # contributor or sharing deploy access.
  backend "local" {}
}

provider "hcloud" {
  token = var.hcloud_token
}
