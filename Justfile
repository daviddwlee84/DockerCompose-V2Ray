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
