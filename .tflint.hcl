# tflint configuration
# https://github.com/terraform-linters/tflint

plugin "hcloud" {
  enabled = true
  version = "0.3.0"
  source  = "github.com/hetznercloud/tflint-ruleset-hcloud"
}

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
