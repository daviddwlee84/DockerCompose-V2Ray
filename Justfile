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

# Smoke-test the deployed host. Pass <rg> (or set DOMAIN / RG); zero-arg uses vms/current when unique.
verify *args:
    scripts/verify.sh {{args}}

# Tail v2ray access log over SSH.
logs-v2ray:
    cd {{ansible_dir}} && ansible vpn -a "tail -n 50 /opt/vpn/runtime/logs/v2ray/access.log"

# Tail nginx error log over SSH.
logs-nginx:
    cd {{ansible_dir}} && ansible vpn -a "tail -n 50 /opt/vpn/runtime/logs/nginx/error.log"

# Show compose service status on the VPS.
ps:
    cd {{ansible_dir}} && ansible vpn -a "docker compose -f /opt/vpn/compose.yml ps"

# Edit the encrypted vault for a specific host (or legacy group vault). Usage: just vault-edit [<rg>]
vault-edit rg="":
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ansible_dir}}
    RG="{{rg}}"
    if [ -n "$RG" ]; then
        target="host_vars/$RG/vault.yml"
        if [ ! -f "$target" ]; then
            echo "[vault-edit] host_vars/$RG/vault.yml not found. Tracked hosts:" >&2
            if compgen -G "host_vars/*/vault.yml" >/dev/null; then
                for f in host_vars/*/vault.yml; do printf '  %s\n' "$(basename "$(dirname "$f")")" >&2; done
            else
                echo "  (none — run 'just az-configure' first)" >&2
            fi
            exit 1
        fi
        exec ansible-vault edit "$target"
    fi
    if compgen -G "host_vars/*/vault.yml" >/dev/null; then
        echo "[vault-edit] Multi-host layout detected — pass <rg>:" >&2
        for f in host_vars/*/vault.yml; do printf '  just vault-edit %s\n' "$(basename "$(dirname "$f")")" >&2; done
        exit 1
    fi
    if [ -f group_vars/vpn/vault.yml ]; then
        echo "[vault-edit] NOTE: editing legacy group_vars/vpn/vault.yml. Once you move to multi-host, use 'just vault-edit <rg>' against host_vars/<rg>/vault.yml. See docs/MULTI-HOST.md." >&2
        exec ansible-vault edit group_vars/vpn/vault.yml
    fi
    echo "[vault-edit] No vault files found. Copy ansible/group_vars/vpn/vault.yml.example or run 'just az-configure'." >&2
    exit 1

# Encrypt a freshly-created vault.yml (one-time after copying from vault.yml.example). Usage: just vault-encrypt [<rg>]
vault-encrypt rg="":
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ansible_dir}}
    RG="{{rg}}"
    if [ -n "$RG" ]; then
        target="host_vars/$RG/vault.yml"
        if [ ! -f "$target" ]; then
            echo "[vault-encrypt] host_vars/$RG/vault.yml not found." >&2
            exit 1
        fi
        exec ansible-vault encrypt "$target"
    fi
    if compgen -G "host_vars/*/vault.yml" >/dev/null; then
        echo "[vault-encrypt] Multi-host layout detected — pass <rg>:" >&2
        for f in host_vars/*/vault.yml; do printf '  just vault-encrypt %s\n' "$(basename "$(dirname "$f")")" >&2; done
        exit 1
    fi
    if [ -f group_vars/vpn/vault.yml ]; then
        echo "[vault-encrypt] NOTE: encrypting legacy group_vars/vpn/vault.yml. For multi-host, prefer 'just vault-encrypt <rg>'. See docs/MULTI-HOST.md." >&2
        exec ansible-vault encrypt group_vars/vpn/vault.yml
    fi
    echo "[vault-encrypt] No vault.yml found to encrypt." >&2
    exit 1

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

# Generate client configs. Pass <rg> (positional / --rg / RG=) when multiple VMs are tracked.
az-client *args:
    scripts/vmess_client.py {{args}}

# Tear down a single tracked Azure RG. Pass <rg> (positional / --rg / RG=); defaults to vms/current.
az-down *args:
    scripts/az_down.sh {{args}}

# Rotate the Azure public IP (keeps FQDN / cert / UUID). Pass <rg> (positional / --rg / RG=); defaults to vms/current.
az-rotate-ip *args:
    scripts/az_rotate_ip.sh {{args}}

# List every tracked Azure VM (.secrets/azure/vms/*.json). '*' marks the vms/current target.
az-list:
    #!/usr/bin/env bash
    set -euo pipefail
    VMS_DIR=".secrets/azure/vms"
    if [ ! -d "$VMS_DIR" ] || ! compgen -G "$VMS_DIR/*.json" >/dev/null; then
        echo "No tracked VMs. Run 'just az-up' to provision one."
        exit 0
    fi
    command -v jq >/dev/null || { echo "[az-list] jq not on PATH (brew install jq)" >&2; exit 1; }
    current=""
    if [ -L "$VMS_DIR/current" ]; then
        current=$(basename "$(readlink "$VMS_DIR/current")" .json)
    fi
    printf '%s %-32s %-55s %-18s %s\n' ' ' 'RG' 'FQDN' 'PUBLIC_IP' 'CREATED_AT'
    printf '%s %-32s %-55s %-18s %s\n' ' ' '--' '----' '---------' '----------'
    for f in "$VMS_DIR"/*.json; do
        base=$(basename "$f")
        [ "$base" = "current" ] && continue
        rg=$(jq -r '.rg // "?"' "$f")
        fqdn=$(jq -r '.fqdn // "?"' "$f")
        ip=$(jq -r '.public_ip // "?"' "$f")
        created=$(jq -r '.created_at // "?"' "$f")
        marker=' '
        [ "$rg" = "$current" ] && marker='*'
        printf '%s %-32s %-55s %-18s %s\n' "$marker" "$rg" "$fqdn" "$ip" "$created"
    done

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
