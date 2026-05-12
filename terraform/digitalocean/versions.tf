terraform {
  required_version = "~> 1.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
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

provider "digitalocean" {
  token = var.do_token
}
