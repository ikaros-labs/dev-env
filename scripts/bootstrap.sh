#!/usr/bin/env bash
# bootstrap.sh — Interactive bootstrap for the dev-env IaC repo.
#
# Walks through the full workflow:
#   1. Validate required tools
#   2. Select cloud provider (Hetzner or DigitalOcean)
#   3. Collect secrets interactively
#   4. Write terraform.tfvars
#   5. terraform init + apply
#   6. Wait for server to join Tailscale
#   7. Generate Ansible inventory
#   8. Install Ansible Galaxy collections
#   9. Set up Ansible Vault
#  10. Run Ansible playbook
#
# Usage:
#   bash scripts/bootstrap.sh [--provider hetzner|digitalocean] [-h|--help]

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
ANSIBLE_DIR="$REPO_ROOT/ansible"
VAULT_PASS_FILE="$HOME/.ansible_vault_pass"
VAULT_FILE="$ANSIBLE_DIR/vault.yml"

# Set by step_choose_provider
PROVIDER=""
TF_DIR=""
TFVARS_FILE=""

# Collected secrets (kept in-memory only)
CLOUD_TOKEN=""
TAILSCALE_AUTH_KEY=""
USERNAME="ikaros"
SUDO_PASSWORD=""
HASHED_PASSWORD=""
SERVER_LOCATION=""
SERVER_TYPE=""
REGION=""
DROPLET_SIZE=""
CADDY_CF_API_TOKEN=""
ANTHROPIC_API_KEY=""
VAULT_PASS=""

# Password hashing method detected in step_check_tools
HASH_METHOD=""

# Arg parsed flags
ARG_PROVIDER=""

# Step counter for headers
_STEP=0
_TOTAL_STEPS=10

# ---------------------------------------------------------------------------
# Colors (only when stdout is a terminal)
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD='\033[1m'
  RESET='\033[0m'
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
else
  BOLD='' RESET='' RED='' GREEN='' YELLOW='' BLUE='' CYAN=''
fi

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

header() {
  _STEP=$(( _STEP + 1 ))
  printf "\n${BOLD}${CYAN}==> [%d/%d] %s${RESET}\n\n" "$_STEP" "$_TOTAL_STEPS" "$1"
}

info()  { printf "  ${BLUE}[i]${RESET} %s\n" "$1"; }
ok()    { printf "  ${GREEN}[ok]${RESET} %s\n" "$1"; }
warn()  { printf "  ${YELLOW}[!]${RESET} %s\n" "$1"; }
err()   { printf "  ${RED}[ERROR]${RESET} %s\n" "$1" >&2; }
die()   { err "$1"; exit 1; }

# ask VAR_NAME PROMPT [DEFAULT]
ask() {
  local __var="$1"
  local __prompt="$2"
  local __default="${3:-}"
  local __input

  if [[ -n "$__default" ]]; then
    printf "  ${BOLD}%s${RESET} [%s]: " "$__prompt" "$__default"
  else
    printf "  ${BOLD}%s${RESET}: " "$__prompt"
  fi

  read -r __input
  if [[ -z "$__input" && -n "$__default" ]]; then
    __input="$__default"
  fi
  printf -v "$__var" '%s' "$__input"
}

# ask_secret VAR_NAME PROMPT
ask_secret() {
  local __var="$1"
  local __prompt="$2"
  local __input

  printf "  ${BOLD}%s${RESET}: " "$__prompt"
  read -rs __input
  printf '\n'
  printf -v "$__var" '%s' "$__input"
}

# confirm PROMPT [y|n] — returns 0 for yes, 1 for no
confirm() {
  local __prompt="$1"
  local __default="${2:-y}"
  local __input

  if [[ "$__default" == "y" ]]; then
    printf "  ${BOLD}%s${RESET} [Y/n]: " "$__prompt"
  else
    printf "  ${BOLD}%s${RESET} [y/N]: " "$__prompt"
  fi

  read -r __input
  __input="${__input:-$__default}"
  [[ "$__input" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --provider|-p)
        ARG_PROVIDER="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
Usage: scripts/bootstrap.sh [OPTIONS]

Interactive bootstrap for the dev-env IaC repository.
Walks through tool validation, secret collection, Terraform, and Ansible.

Options:
  --provider, -p <hetzner|digitalocean>  Pre-select cloud provider
  -h, --help                             Show this help message

Secrets are collected interactively (never via command-line arguments).
EOF
        exit 0
        ;;
      *)
        die "Unknown argument: $1. Run with --help for usage."
        ;;
    esac
  done

  if [[ -n "$ARG_PROVIDER" && "$ARG_PROVIDER" != "hetzner" && "$ARG_PROVIDER" != "digitalocean" ]]; then
    die "Invalid --provider value '$ARG_PROVIDER'. Must be 'hetzner' or 'digitalocean'."
  fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

print_banner() {
  printf "\n${BOLD}${CYAN}"
  cat <<'EOF'
  ┌─────────────────────────────────────────┐
  │   dev-env bootstrap                     │
  │   Terraform + Ansible + Tailscale       │
  └─────────────────────────────────────────┘
EOF
  printf "${RESET}"
  printf "  This script will guide you through provisioning a cloud dev server.\n"
  printf "  Secrets are collected interactively and never logged to disk as plaintext.\n\n"
}

# ---------------------------------------------------------------------------
# Step 1: Check required tools
# ---------------------------------------------------------------------------

step_check_tools() {
  header "Checking required tools"

  local os
  os="$(uname -s)"
  local missing_required=false

  _check_tool() {
    local tool="$1"
    local required="${2:-true}"
    local install_mac="${3:-}"
    local install_linux="${4:-}"

    if command -v "$tool" &>/dev/null; then
      local ver
      ver="$("$tool" --version 2>&1 | head -1)" || ver="(version unknown)"
      ok "$tool  —  $ver"
    else
      if [[ "$required" == "true" ]]; then
        err "$tool is not installed."
        if [[ "$os" == "Darwin" && -n "$install_mac" ]]; then
          info "  Install: $install_mac"
        elif [[ -n "$install_linux" ]]; then
          info "  Install: $install_linux"
        fi
        missing_required=true
      else
        warn "$tool not found (optional)."
        if [[ "$os" == "Darwin" && -n "$install_mac" ]]; then
          info "  Install: $install_mac"
        elif [[ -n "$install_linux" ]]; then
          info "  Install: $install_linux"
        fi
      fi
    fi
  }

  _check_tool terraform    true  "brew install terraform"          "See developer.hashicorp.com/terraform/install"
  _check_tool ansible      true  "brew install ansible"            "pip install ansible"
  _check_tool ansible-vault true "(installed with ansible)"        "(installed with ansible)"
  _check_tool ansible-galaxy true "(installed with ansible)"       "(installed with ansible)"
  _check_tool ansible-playbook true "(installed with ansible)"     "(installed with ansible)"
  _check_tool tailscale    true  "brew install tailscale"          "curl -fsSL https://tailscale.com/install.sh | sh"
  _check_tool python3      true  "brew install python3"            "apt install python3"
  _check_tool pre-commit   false "pip install pre-commit"          "pip install pre-commit"
  _check_tool tflint       false "brew install tflint"             "See github.com/terraform-linters/tflint"

  if [[ "$missing_required" == "true" ]]; then
    die "One or more required tools are missing. Install them and re-run."
  fi

  # Detect password hashing method
  printf "\n"
  info "Detecting password hashing tool..."

  if command -v mkpasswd &>/dev/null && mkpasswd --help 2>&1 | grep -q '\-m'; then
    HASH_METHOD="mkpasswd"
    ok "Password hashing: mkpasswd"
  elif openssl passwd -6 -salt testsalt testpass &>/dev/null 2>&1; then
    HASH_METHOD="openssl"
    ok "Password hashing: openssl"
  elif python3 -c "import crypt" &>/dev/null 2>&1; then
    HASH_METHOD="python3-crypt"
    ok "Password hashing: python3 crypt module"
  else
    die "No SHA-512 password hashing tool found.\n  Install one of:\n    Debian/Ubuntu: sudo apt install whois\n    macOS: brew install --cask whois"
  fi

  # Offer pre-commit hook installation
  if command -v pre-commit &>/dev/null; then
    printf "\n"
    if [[ ! -f "$REPO_ROOT/.git/hooks/pre-commit" ]]; then
      if confirm "Install pre-commit hooks?"; then
        (cd "$REPO_ROOT" && pre-commit install)
        ok "pre-commit hooks installed."
      fi
    else
      ok "pre-commit hooks already installed."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 2: Choose cloud provider
# ---------------------------------------------------------------------------

step_choose_provider() {
  header "Selecting cloud provider"

  local hetzner_has_state=false
  local do_has_state=false

  [[ -f "$REPO_ROOT/terraform/hetzner/terraform.tfstate" ]] && hetzner_has_state=true
  [[ -f "$REPO_ROOT/terraform/digitalocean/terraform.tfstate" ]] && do_has_state=true

  if [[ "$hetzner_has_state" == "true" && "$do_has_state" == "true" ]]; then
    die "Terraform state exists for both providers.\nRun 'terraform destroy' in one before re-bootstrapping."
  fi

  if [[ -n "$ARG_PROVIDER" ]]; then
    PROVIDER="$ARG_PROVIDER"
    info "Using provider from --provider flag: $PROVIDER"
  elif [[ "$hetzner_has_state" == "true" ]]; then
    info "Existing Terraform state found for: hetzner"
    if confirm "Continue with Hetzner?"; then
      PROVIDER="hetzner"
    else
      die "Run 'terraform destroy' in terraform/hetzner/ first, then re-run this script."
    fi
  elif [[ "$do_has_state" == "true" ]]; then
    info "Existing Terraform state found for: DigitalOcean"
    if confirm "Continue with DigitalOcean?"; then
      PROVIDER="digitalocean"
    else
      die "Run 'terraform destroy' in terraform/digitalocean/ first, then re-run this script."
    fi
  else
    printf "  Which cloud provider?\n"
    printf "    1) Hetzner Cloud\n"
    printf "    2) DigitalOcean\n\n"
    local choice
    ask choice "Choice" "1"
    case "$choice" in
      1) PROVIDER="hetzner" ;;
      2) PROVIDER="digitalocean" ;;
      *) die "Invalid choice '$choice'." ;;
    esac
  fi

  TF_DIR="$REPO_ROOT/terraform/$PROVIDER"
  TFVARS_FILE="$TF_DIR/terraform.tfvars"
  ok "Provider: $PROVIDER"
}

# ---------------------------------------------------------------------------
# Step 3: Collect secrets
# ---------------------------------------------------------------------------

_generate_hash() {
  local password="$1"
  local hash

  case "$HASH_METHOD" in
    mkpasswd)
      hash="$(printf '%s' "$password" | mkpasswd -m sha-512 --stdin)"
      ;;
    openssl)
      # Generate a random 16-char salt
      local salt
      salt="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)"
      hash="$(printf '%s' "$password" | openssl passwd -6 -salt "$salt" -stdin)"
      ;;
    python3-crypt)
      hash="$(python3 -c "
import crypt, sys
pw = sys.stdin.readline().rstrip('\n')
print(crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512)))
" <<< "$password")"
      ;;
  esac

  printf '%s' "$hash"
}

step_collect_secrets() {
  header "Collecting secrets"
  info "All sensitive inputs are hidden. They are kept in memory and never written to plain-text files."

  printf "\n"

  # 3a: Cloud API token
  case "$PROVIDER" in
    hetzner)
      info "Hetzner API token — create at: https://console.hetzner.cloud → project → Security → API Tokens (Read+Write)"
      ;;
    digitalocean)
      info "DigitalOcean API token — create at: https://cloud.digitalocean.com/account/api/tokens (Read+Write scope)"
      ;;
  esac
  ask_secret CLOUD_TOKEN "Cloud API token"
  [[ -z "$CLOUD_TOKEN" ]] && die "Cloud API token is required."
  if [[ ${#CLOUD_TOKEN} -lt 32 ]]; then
    warn "Token looks short (${#CLOUD_TOKEN} chars). Proceeding, but double-check it."
  fi
  ok "Cloud API token collected."

  printf "\n"

  # 3b: Tailscale auth key
  info "Tailscale auth key — create at: https://login.tailscale.com/admin/settings/keys"
  info "  Settings: Reusable=on, Ephemeral=off, Pre-authorized=on, Tags=tag:dev-env"
  ask_secret TAILSCALE_AUTH_KEY "Tailscale auth key"
  [[ -z "$TAILSCALE_AUTH_KEY" ]] && die "Tailscale auth key is required."
  if [[ "$TAILSCALE_AUTH_KEY" != tskey-auth-* ]]; then
    warn "Key doesn't start with 'tskey-auth-' — is this correct?"
    confirm "Continue anyway?" || die "Aborted."
  fi
  ok "Tailscale auth key collected."

  printf "\n"

  # 3c: Username
  ask USERNAME "Linux username" "ikaros"
  if ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    die "Invalid username '$USERNAME'. Must match ^[a-z_][a-z0-9_-]*$"
  fi
  ok "Username: $USERNAME"

  printf "\n"

  # 3d: Sudo password + hash
  local attempts=0
  while true; do
    ask_secret SUDO_PASSWORD "Sudo password for $USERNAME"
    [[ -z "$SUDO_PASSWORD" ]] && { err "Password cannot be empty."; continue; }
    local confirm_pass
    ask_secret confirm_pass "Confirm sudo password"
    if [[ "$SUDO_PASSWORD" == "$confirm_pass" ]]; then
      break
    fi
    attempts=$(( attempts + 1 ))
    err "Passwords do not match."
    [[ $attempts -ge 3 ]] && die "Too many failed attempts."
  done

  info "Generating SHA-512 password hash..."
  HASHED_PASSWORD="$(_generate_hash "$SUDO_PASSWORD")"
  if [[ "$HASHED_PASSWORD" != '$6$'* ]]; then
    die "Hash generation failed — output does not start with '\$6\$': $HASHED_PASSWORD"
  fi
  ok "Password hash generated."

  printf "\n"

  # 3e: Optional server customization
  if confirm "Customize server settings (location/size)?" "n"; then
    case "$PROVIDER" in
      hetzner)
        ask SERVER_LOCATION "Server location (fsn1/nbg1/hel1/ash/hil)" "fsn1"
        ask SERVER_TYPE "Server type (cx23/cx33/cx43)" "cx23"
        ;;
      digitalocean)
        ask REGION "Region (fra1/ams3/nyc3/lon1/sgp1/sfo3)" "fra1"
        ask DROPLET_SIZE "Droplet size" "s-2vcpu-4gb"
        ;;
    esac
  else
    case "$PROVIDER" in
      hetzner)
        SERVER_LOCATION="fsn1"
        SERVER_TYPE="cx23"
        ;;
      digitalocean)
        REGION="fra1"
        DROPLET_SIZE="s-2vcpu-4gb"
        ;;
    esac
    ok "Using default server settings."
  fi

  printf "\n"

  # 3f: Ansible vault secrets
  info "The following secrets are stored in an encrypted Ansible Vault file."
  printf "\n"

  info "Cloudflare API token — used by Caddy for DNS-01 ACME challenges."
  info "  Create at: https://dash.cloudflare.com/profile/api-tokens"
  ask_secret CADDY_CF_API_TOKEN "Cloudflare API token"
  [[ -z "$CADDY_CF_API_TOKEN" ]] && die "Cloudflare API token is required."
  ok "Cloudflare API token collected."

  printf "\n"

  info "Anthropic API key — used by Claude Code and the agents-orchestrator service."
  info "  Create at: https://console.anthropic.com/account/keys"
  ask_secret ANTHROPIC_API_KEY "Anthropic API key"
  [[ -z "$ANTHROPIC_API_KEY" ]] && die "Anthropic API key is required."
  ok "Anthropic API key collected."

  printf "\n"

  # 3g: Vault password
  if [[ -f "$VAULT_PASS_FILE" ]]; then
    warn "~/.ansible_vault_pass already exists."
    if confirm "Use the existing vault password?"; then
      VAULT_PASS="$(cat "$VAULT_PASS_FILE")"
      ok "Using existing vault password."
      return
    fi
  fi

  info "Choose a password to encrypt the Ansible vault file."
  local vattempts=0
  while true; do
    ask_secret VAULT_PASS "Ansible vault password"
    if [[ ${#VAULT_PASS} -lt 8 ]]; then
      err "Vault password must be at least 8 characters."
      vattempts=$(( vattempts + 1 ))
      [[ $vattempts -ge 3 ]] && die "Too many failed attempts."
      continue
    fi
    local vpass_confirm
    ask_secret vpass_confirm "Confirm vault password"
    if [[ "$VAULT_PASS" == "$vpass_confirm" ]]; then
      break
    fi
    err "Passwords do not match."
    vattempts=$(( vattempts + 1 ))
    [[ $vattempts -ge 3 ]] && die "Too many failed attempts."
  done
  ok "Vault password set."
}

# ---------------------------------------------------------------------------
# Step 4: Write terraform.tfvars
# ---------------------------------------------------------------------------

step_write_tfvars() {
  header "Writing terraform.tfvars"

  if [[ -f "$TFVARS_FILE" ]]; then
    warn "terraform.tfvars already exists: $TFVARS_FILE"
    if ! confirm "Overwrite with new values?"; then
      ok "Keeping existing terraform.tfvars."
      return
    fi
    local backup="$TFVARS_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$TFVARS_FILE" "$backup"
    info "Backed up existing file to: $backup"
  fi

  # Use printf to avoid heredoc interpolation issues with '$6$' in hashed password
  case "$PROVIDER" in
    hetzner)
      {
        printf 'hcloud_token         = "%s"\n' "$CLOUD_TOKEN"
        printf 'tailscale_auth_key   = "%s"\n' "$TAILSCALE_AUTH_KEY"
        printf 'user_hashed_password = "%s"\n' "$HASHED_PASSWORD"
        printf 'username             = "%s"\n' "$USERNAME"
        printf 'server_location      = "%s"\n' "$SERVER_LOCATION"
        printf 'server_type          = "%s"\n' "$SERVER_TYPE"
      } > "$TFVARS_FILE"
      ;;
    digitalocean)
      {
        printf 'do_token             = "%s"\n' "$CLOUD_TOKEN"
        printf 'tailscale_auth_key   = "%s"\n' "$TAILSCALE_AUTH_KEY"
        printf 'user_hashed_password = "%s"\n' "$HASHED_PASSWORD"
        printf 'username             = "%s"\n' "$USERNAME"
        printf 'region               = "%s"\n' "$REGION"
        printf 'droplet_size         = "%s"\n' "$DROPLET_SIZE"
      } > "$TFVARS_FILE"
      ;;
  esac

  chmod 600 "$TFVARS_FILE"
  ok "terraform.tfvars written to $TFVARS_FILE (mode 0600)"
}

# ---------------------------------------------------------------------------
# Step 5: Terraform init + apply
# ---------------------------------------------------------------------------

step_terraform_init_apply() {
  header "Running Terraform"

  # Check if infrastructure already exists
  if [[ -f "$TF_DIR/terraform.tfstate" ]]; then
    local server_count
    server_count="$(terraform -chdir="$TF_DIR" output -json server_usernames 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo 0)"
    if [[ "$server_count" -gt 0 ]]; then
      info "Terraform state already contains $server_count provisioned server(s)."
      if confirm "Skip terraform apply (use existing infrastructure)?"; then
        ok "Skipping terraform apply."
        return
      fi
    fi
  fi

  # Init
  info "Running terraform init..."
  if [[ -d "$TF_DIR/.terraform" ]]; then
    info "(.terraform directory exists, running init to check for updates)"
  fi
  terraform -chdir="$TF_DIR" init -input=false
  ok "Terraform initialized."

  printf "\n"

  # Plan
  info "Running terraform plan..."
  local plan_out="$TF_DIR/.bootstrap.tfplan"
  terraform -chdir="$TF_DIR" plan -input=false -out="$plan_out"

  printf "\n"

  # Apply
  warn "This will create cloud resources (costs will apply)."
  if ! confirm "Proceed with terraform apply?"; then
    rm -f "$plan_out"
    die "Aborted by user."
  fi

  info "Applying Terraform plan (this usually takes ~30 seconds)..."
  terraform -chdir="$TF_DIR" apply -input=false "$plan_out"
  rm -f "$plan_out"

  ok "Terraform apply complete."
  printf "\n"
  info "Provisioned servers:"
  terraform -chdir="$TF_DIR" output server_usernames 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Step 6: Wait for Tailscale
# ---------------------------------------------------------------------------

step_wait_tailscale() {
  header "Waiting for server to join Tailscale"

  # Check local Tailscale is running
  if ! tailscale status &>/dev/null 2>&1; then
    die "Cannot reach Tailscale. Make sure Tailscale is running and you are logged in.\n  Try: tailscale up"
  fi

  # Get server names from Terraform
  local server_names
  server_names="$(terraform -chdir="$TF_DIR" output -json server_usernames 2>/dev/null \
    | python3 -c "import sys,json; [print(k) for k in sorted(json.load(sys.stdin).keys())]" 2>/dev/null)"

  if [[ -z "$server_names" ]]; then
    warn "Could not read server names from Terraform output. Skipping Tailscale check."
    return
  fi

  info "Waiting for these servers to appear on the tailnet: $server_names"
  info "Cloud-init runs tailscale up on first boot — this takes 30-60 seconds."
  printf "\n"

  local max_attempts=24
  local interval=5
  local all_found=true

  while IFS= read -r server_name; do
    [[ -z "$server_name" ]] && continue
    info "Polling for: $server_name"

    local found=false
    for i in $(seq 1 $max_attempts); do
      if tailscale status 2>/dev/null | grep -q "$server_name"; then
        ok "  '$server_name' is on the tailnet."
        found=true
        break
      fi
      printf "\r  ${YELLOW}[!]${RESET}  %d/%d — waiting... (%ds elapsed)" \
        "$i" "$max_attempts" "$(( i * interval ))"
      sleep "$interval"
    done

    if [[ "$found" == "false" ]]; then
      printf "\n"
      err "'$server_name' did not appear on the tailnet within $(( max_attempts * interval )) seconds."
      all_found=false
    fi
    printf "\n"

  done <<< "$server_names"

  if [[ "$all_found" == "false" ]]; then
    warn "Some servers are not yet on the tailnet."
    info "The server may still be running cloud-init. You can:"
    info "  1. Wait a minute and check: tailscale status"
    info "  2. Re-run this script — it will resume from where it left off."
    if ! confirm "Continue anyway?"; then
      die "Aborted. Re-run when servers are on the tailnet."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 7: Generate Ansible inventory
# ---------------------------------------------------------------------------

step_generate_inventory() {
  header "Generating Ansible inventory"

  if [[ -f "$ANSIBLE_DIR/hosts.ini" ]]; then
    info "Existing inventory found — regenerating from current Terraform state."
  fi

  bash "$SCRIPTS_DIR/gen-inventory.sh" --tf-dir "$TF_DIR"

  printf "\n"
  info "Generated inventory:"
  printf "${CYAN}"
  cat "$ANSIBLE_DIR/hosts.ini"
  printf "${RESET}\n"

  ok "Inventory written to ansible/hosts.ini"
}

# ---------------------------------------------------------------------------
# Step 8: Ansible Galaxy collections
# ---------------------------------------------------------------------------

step_ansible_galaxy() {
  header "Installing Ansible Galaxy collections"

  local collections_dir="$ANSIBLE_DIR/collections/ansible_collections/community/general"

  if [[ -d "$collections_dir" ]]; then
    info "community.general collection already installed."
    if ! confirm "Reinstall/update?"; then
      ok "Skipping Galaxy install."
      return
    fi
  fi

  ansible-galaxy collection install \
    --requirements-file "$ANSIBLE_DIR/requirements.yml" \
    --collections-path "$ANSIBLE_DIR/collections"

  ok "Ansible Galaxy collections installed."
}

# ---------------------------------------------------------------------------
# Step 9: Set up Ansible Vault
# ---------------------------------------------------------------------------

step_setup_vault() {
  header "Setting up Ansible Vault"

  # 9a: Write vault password file
  printf '%s' "$VAULT_PASS" > "$VAULT_PASS_FILE"
  chmod 600 "$VAULT_PASS_FILE"
  ok "Vault password written to $VAULT_PASS_FILE (mode 0600)"

  printf "\n"

  # 9b: Create/update vault.yml
  if [[ -f "$VAULT_FILE" ]]; then
    warn "ansible/vault.yml already exists (encrypted)."
    if ! confirm "Overwrite with collected secrets?"; then
      ok "Keeping existing vault.yml."
      return
    fi
  fi

  info "Encrypting secrets into ansible/vault.yml..."

  # Build YAML safely using python3 + json.dumps to handle special characters
  local vault_content
  vault_content="$(python3 -c "
import json, sys
args = sys.argv[1:]
vals = [json.dumps(v) for v in args]
print('---')
print('ansible_become_pass: ' + vals[0])
print('caddy_cf_api_token: ' + vals[1])
print('anthropic_api_key: ' + vals[2])
" "$SUDO_PASSWORD" "$CADDY_CF_API_TOKEN" "$ANTHROPIC_API_KEY")"

  # Encrypt via ansible-vault
  printf '%s\n' "$vault_content" \
    | ansible-vault encrypt \
        --vault-password-file "$VAULT_PASS_FILE" \
        --output "$VAULT_FILE" \
        /dev/stdin

  ok "ansible/vault.yml encrypted and written."
}

# ---------------------------------------------------------------------------
# Step 10: Run Ansible playbook
# ---------------------------------------------------------------------------

step_run_playbook() {
  header "Running Ansible playbook"

  info "This will fully configure the server (Docker, Node.js, Caddy, Claude Code, etc.)."
  info "Typically takes 5-10 minutes on a fresh server."
  printf "\n"

  if ! confirm "Proceed with ansible-playbook?"; then
    die "Aborted by user."
  fi

  # Run from inside ansible/ so relative paths in ansible.cfg resolve correctly
  (cd "$ANSIBLE_DIR" && ansible-playbook playbooks/setup.yml)

  ok "Ansible playbook completed successfully."
}

# ---------------------------------------------------------------------------
# Success banner
# ---------------------------------------------------------------------------

print_success() {
  printf "\n${BOLD}${GREEN}"
  cat <<'EOF'
  ╔════════════════════════════════════════╗
  ║   Bootstrap complete!                  ║
  ╚════════════════════════════════════════╝
EOF
  printf "${RESET}"

  local server_name="${USERNAME}@dev-env"
  printf "\n  Your dev environment is ready.\n\n"
  printf "  ${BOLD}Connect:${RESET}\n"
  printf "    ssh %s\n" "$server_name"
  printf "    tailscale ssh %s\n" "$server_name"
  printf "\n"
  printf "  ${BOLD}Services deployed:${RESET}\n"
  printf "    Docker, code-server, Caddy, CoreDNS\n"
  printf "    Claude Code, Playwright, agents-orchestrator\n"
  printf "\n"
  printf "  ${BOLD}To re-run the playbook:${RESET}\n"
  printf "    cd ansible && ansible-playbook playbooks/setup.yml\n"
  printf "\n"
  printf "  ${BOLD}To tear down:${RESET}\n"
  printf "    cd terraform/%s && terraform destroy\n" "$PROVIDER"
  printf "    (Also remove the device from https://login.tailscale.com/admin/machines)\n"
  printf "\n"
}

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------

trap 'err "Unexpected error at line $LINENO. Exiting."; exit 1' ERR

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  print_banner
  step_check_tools
  step_choose_provider
  step_collect_secrets
  step_write_tfvars
  step_terraform_init_apply
  step_wait_tailscale
  step_generate_inventory
  step_ansible_galaxy
  step_setup_vault
  step_run_playbook
  print_success
}

main "$@"
