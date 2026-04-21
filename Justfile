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

# One-time laptop setup: install ansible, jq, uv (brew/apt auto-detected) and fetch ansible-galaxy collections. Idempotent.
setup:
    #!/usr/bin/env bash
    set -euo pipefail

    missing=()
    for t in ansible jq uv; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        echo "[setup] ansible, jq, uv already on PATH — nothing to install."
    else
        echo "[setup] Missing: ${missing[*]}"
        if command -v brew >/dev/null 2>&1; then
            echo "[setup] Using Homebrew."
            brew install "${missing[@]}"
        elif [ -f /etc/os-release ] && grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release; then
            echo "[setup] Using apt (Debian/Ubuntu detected)."
            apt_pkgs=()
            install_uv=0
            for t in "${missing[@]}"; do
                case "$t" in
                    ansible|jq) apt_pkgs+=("$t") ;;
                    uv)         install_uv=1 ;;
                esac
            done
            if [ ${#apt_pkgs[@]} -gt 0 ]; then
                sudo apt-get update
                sudo apt-get install -y "${apt_pkgs[@]}"
            fi
            # uv isn't in Debian/Ubuntu apt yet; use Astral's official installer
            # (lands in ~/.local/bin — make sure that's on PATH afterwards).
            if [ $install_uv -eq 1 ]; then
                echo "[setup] Installing uv via astral.sh installer..."
                curl -LsSf https://astral.sh/uv/install.sh | sh
            fi
        else
            echo "[setup] No brew or apt detected on this OS." >&2
            echo "[setup] Install manually: ${missing[*]}" >&2
            echo "[setup] See README.md 'Deploy' section for install options." >&2
            exit 1
        fi
    fi

    echo "[setup] Fetching ansible-galaxy collections..."
    cd {{ansible_dir}} && ansible-galaxy install -r requirements.yml

    if ! command -v az >/dev/null 2>&1; then
        echo
        echo "[setup] NOTE: for the Azure throwaway flow (just az-*), also install:"
        echo "          brew install azure-cli     # macOS / Linuxbrew"
        echo "          sudo apt install azure-cli # Debian/Ubuntu 24.04+"
        echo "          https://learn.microsoft.com/cli/azure/install-azure-cli"
    fi
    echo "[setup] Done."

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
#
# State layout (see docs/MULTI-HOST.md):
#   .secrets/azure/vms/<rg>.json  per-VM handoff
#   .secrets/azure/vms/current    symlink to the most recently created VM
#   .secrets/azure/last-vm.json   legacy mirror (still written for older readers)
#
# az-client / az-down / az-rotate-ip take an optional <rg> positional arg (or
# RG= env var). With exactly one VM tracked, they default to it; with >1 they
# require an explicit RG.

# Provision a cheap Azure VM + DNS name (writes .secrets/azure/vms/<rg>.json).
az-up *args:
    scripts/az_up.sh {{args}}

# Render ansible inventory + per-host vaults from vms/*.json (uses git email for LE).
az-configure *args:
    scripts/az_configure.py {{args}}

# Generate client configs. Pass --rg <rg> (or RG=<rg>) to pick when multiple VMs are tracked.
az-client *args:
    scripts/vmess_client.py {{args}}

# Tear down a single tracked Azure RG. Pass <rg> to target a specific VM; defaults to vms/current.
az-down *args:
    scripts/az_down.sh {{args}}

# Rotate the Azure public IP (keeps FQDN / cert / UUID). Pass <rg> or set AZ_RG; defaults to vms/current.
az-rotate-ip *args:
    scripts/az_rotate_ip.sh {{args}}

# One-shot single-VM loop: provision → configure → deploy → verify → client-config → pause → teardown. For multi-region, run az-up per region manually then `just deploy`.
az-cycle:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts/az_up.sh
    RG=$(basename "$(readlink .secrets/azure/vms/current)" .json)
    echo "[az-cycle] Tracking RG=$RG for this cycle."
    scripts/az_configure.py
    # Vault password file is now at .secrets/.vault-pass (or wherever resolve_vault_pass_file() decided).
    export ANSIBLE_VAULT_PASSWORD_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$PWD/.secrets/.vault-pass}"
    just deploy
    DOMAIN=$(jq -r .fqdn ".secrets/azure/vms/$RG.json") just verify
    scripts/vmess_client.py --rg "$RG"
    echo
    echo "[az-cycle] VM is live (RG=$RG). Test the client config, then press Enter to tear down."
    read -r _
    scripts/az_down.sh "$RG" -y

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
