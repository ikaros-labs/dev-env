# tflint configuration
# https://github.com/terraform-linters/tflint
# Provider-specific plugins live in terraform/hetzner/.tflint.hcl and
# terraform/digitalocean/.tflint.hcl to avoid cross-provider false positives.

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}
