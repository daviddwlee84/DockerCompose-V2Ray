# Laptop-side wrapper for ansible deploys.
#
# Usage: `just` to list targets. Override ansible invocation by exporting
# ANSIBLE_OPTS='--ask-vault-pass' or similar.
#
# The DOMAIN env var is needed for `just verify` (the deployed hostname).

set dotenv-load := false
ansible_dir := "ansible"
ansible_opts := env_var_or_default("ANSIBLE_OPTS", "")

default:
    @just --list

# Install galaxy collections required by the playbooks.
galaxy:
    cd {{ansible_dir}} && ansible-galaxy install -r requirements.yml

# Full deploy: common + docker + vpn + letsencrypt.
deploy:
    cd {{ansible_dir}} && ansible-playbook playbooks/site.yml {{ansible_opts}}

# App-only redeploy. Skips OS hardening / docker install.
deploy-fast:
    cd {{ansible_dir}} && ansible-playbook playbooks/deploy.yml {{ansible_opts}}

# Rotate V2Ray UUID. Generates a new UUID, deploys it, then remind to update vault.
rotate-uuid:
    cd {{ansible_dir}} && ansible-playbook playbooks/rotate-uuid.yml -e new_uuid=$(uuidgen) {{ansible_opts}}

# Smoke-test the deployed host. Requires DOMAIN env var.
verify:
    scripts/verify.sh

# Tail v2ray access log over SSH.
logs-v2ray:
    cd {{ansible_dir}} && ansible vpn -a "tail -n 50 /opt/vpn/runtime/logs/v2ray/access.log"

# Tail nginx error log over SSH.
logs-nginx:
    cd {{ansible_dir}} && ansible vpn -a "tail -n 50 /opt/vpn/runtime/logs/nginx/error.log"

# Show compose service status on the VPS.
ps:
    cd {{ansible_dir}} && ansible vpn -a "docker compose -f /opt/vpn/compose.yml ps"

# Edit the encrypted vault.
vault-edit:
    cd {{ansible_dir}} && ansible-vault edit group_vars/vpn/vault.yml

# Encrypt a freshly-created vault.yml (one-time after copying from vault.yml.example).
vault-encrypt:
    cd {{ansible_dir}} && ansible-vault encrypt group_vars/vpn/vault.yml

# --- Azure throwaway validation ---

# Provision a cheap Azure VM + DNS name (writes .secrets/azure/last-vm.json).
az-up *args:
    scripts/az_up.sh {{args}}

# Render ansible inventory + vault from last-vm.json (uses git email for LE).
az-configure *args:
    scripts/az_configure.py {{args}}

# Generate client configs (vmess://, JSON, Clash YAML, human md, PNG + ASCII QR).
az-client *args:
    scripts/vmess_client.py {{args}}

# Tear down the Azure RG tracked in last-vm.json (use `-y` to skip the prompt).
az-down *args:
    scripts/az_down.sh {{args}}

# One-shot: provision → configure → deploy → verify → client-config → pause → teardown.
az-cycle:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts/az_up.sh
    scripts/az_configure.py
    # Vault password file is now at .secrets/.vault-pass (or wherever resolve_vault_pass_file() decided).
    export ANSIBLE_VAULT_PASSWORD_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$PWD/.secrets/.vault-pass}"
    just deploy
    DOMAIN=$(jq -r .fqdn .secrets/azure/last-vm.json) just verify
    scripts/vmess_client.py
    echo
    echo "[az-cycle] VM is live. Test the client config, then press Enter to tear down."
    read -r _
    scripts/az_down.sh -y

# --- local Docker test harness ---

# Generate a throwaway SSH keypair for the test container (first-time setup).
test-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p test/ssh
    if [ ! -f test/ssh/id_ed25519 ]; then
        ssh-keygen -t ed25519 -N '' -f test/ssh/id_ed25519 -C 'vpn-test@local'
        echo "Generated test/ssh/id_ed25519 (gitignored)."
    else
        echo "test/ssh/id_ed25519 already exists."
    fi

# Build the test image and start the SSH container (bound to 127.0.0.1:2222).
test-up: test-setup
    cd test && docker compose -f docker-compose.test.yml up -d --build

# Ansible connectivity check against the test container.
test-ping:
    cd {{ansible_dir}} && ansible -i inventory/test.ini vpn -m ping

# Tear down the test container.
test-down:
    cd test && docker compose -f docker-compose.test.yml down -v
