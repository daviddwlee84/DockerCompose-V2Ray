#!/usr/bin/env bash
# Provision a throwaway Azure VM for end-to-end validation of the V2Ray deploy.
#
# Requires: az CLI (already logged in, `az account show` should work).
# Writes:   .secrets/azure/last-vm.json with everything the rest of the flow needs.
#
# All inputs are env vars with sensible defaults. Override any of them inline:
#   AZ_LOCATION=eastasia AZ_VM_SIZE=Standard_B1s scripts/az_up.sh
#
# Safe to re-run as long as AZ_RG is distinct — `az group list -o table` shows leaks.

set -euo pipefail

# --- inputs ----------------------------------------------------------------

: "${AZ_LOCATION:=japaneast}"
: "${AZ_VM_NAME:=vpn}"
: "${AZ_VM_SIZE:=Standard_B2ats_v2}"
# Use the full URN; the 'Ubuntu2404' alias has intermittent parsing bugs in
# az CLI 2.85 (ERROR: Extra data: line 1 column 4). Stick to the URN.
: "${AZ_IMAGE:=Canonical:ubuntu-24_04-lts:server:latest}"
: "${AZ_ADMIN_USER:=azureuser}"
# If no SSH pubkey is configured, auto-generate a throwaway ed25519 keypair
# under .secrets/azure/ so the flow works on fresh machines with no ~/.ssh/id_ed25519.
if [ -z "${AZ_SSH_PUBKEY:-}" ]; then
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        AZ_SSH_PUBKEY="$HOME/.ssh/id_ed25519.pub"
    else
        mkdir -p ".secrets/azure"
        if [ ! -f ".secrets/azure/id_ed25519" ]; then
            ssh-keygen -t ed25519 -N '' -f ".secrets/azure/id_ed25519" -C "vpn-az-throwaway" >/dev/null
        fi
        AZ_SSH_PUBKEY="$PWD/.secrets/azure/id_ed25519.pub"
    fi
fi

# Generated defaults (only if caller didn't pre-set them).
if [ -z "${AZ_RG:-}" ]; then
    AZ_RG="vpn-test-$(whoami | tr -cd '[:alnum:]')-$(date +%s)"
fi
if [ -z "${AZ_DNS_PREFIX:-}" ]; then
    AZ_DNS_PREFIX="vpn-$(openssl rand -hex 4)"
fi

OUT_DIR=".secrets/azure"
OUT_FILE="$OUT_DIR/last-vm.json"

# --- preflight -------------------------------------------------------------

log() { printf '[az-up] %s\n' "$*" >&2; }
die() { printf '[az-up] ERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "az CLI not found on PATH"
command -v jq >/dev/null || die "jq not found on PATH (brew install jq)"

az account show >/dev/null 2>&1 || die "az CLI not logged in — run 'az login' first"

[ -f "$AZ_SSH_PUBKEY" ] || die "SSH pubkey not found: $AZ_SSH_PUBKEY (generate one with ssh-keygen -t ed25519)"

# Guard against stale state: if last-vm.json already exists, refuse unless
# caller explicitly asked to overwrite. Prevents accidentally orphaning a VM.
if [ -f "$OUT_FILE" ] && [ "${AZ_OVERWRITE:-0}" != "1" ]; then
    die "$OUT_FILE already exists. Run 'just az-down' first, or set AZ_OVERWRITE=1 to clobber (this will ORPHAN the previously-tracked VM)."
fi

# --- provision -------------------------------------------------------------

log "Using subscription: $(az account show --query name -o tsv)"
log "Resource group:     $AZ_RG ($AZ_LOCATION)"
log "VM:                 $AZ_VM_NAME ($AZ_VM_SIZE, $AZ_IMAGE)"
log "DNS prefix:         $AZ_DNS_PREFIX"
log "SSH pubkey:         $AZ_SSH_PUBKEY"

log "Creating resource group..."
az group create --name "$AZ_RG" --location "$AZ_LOCATION" --output none

# DNS name must be globally unique within the region. Retry once with a fresh
# random prefix if the first one collides (unlikely with rand -hex 4 but cheap
# to defend against).
create_vm() {
    local dns_prefix="$1"
    az vm create \
        --resource-group "$AZ_RG" \
        --name "$AZ_VM_NAME" \
        --image "$AZ_IMAGE" \
        --size "$AZ_VM_SIZE" \
        --admin-username "$AZ_ADMIN_USER" \
        --ssh-key-values "$AZ_SSH_PUBKEY" \
        --public-ip-sku Standard \
        --public-ip-address-dns-name "$dns_prefix" \
        --nsg-rule SSH \
        --output json
}

log "Creating VM (this takes ~60-90s)..."
set +e
VM_JSON=$(create_vm "$AZ_DNS_PREFIX" 2>&1)
rc=$?
set -e

if [ $rc -ne 0 ] && echo "$VM_JSON" | grep -qi 'dns.*already'; then
    log "DNS prefix $AZ_DNS_PREFIX collided, retrying with a fresh one..."
    AZ_DNS_PREFIX="vpn-$(openssl rand -hex 4)"
    log "New DNS prefix:     $AZ_DNS_PREFIX"
    VM_JSON=$(create_vm "$AZ_DNS_PREFIX")
elif [ $rc -ne 0 ]; then
    printf '%s\n' "$VM_JSON" >&2
    die "az vm create failed (exit $rc)"
fi

PUBLIC_IP=$(echo "$VM_JSON" | jq -r '.publicIpAddress')
[ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "null" ] || die "failed to parse public IP from az vm create output"

FQDN="${AZ_DNS_PREFIX}.${AZ_LOCATION}.cloudapp.azure.com"

log "Opening NSG ports 80 and 443 (22 was opened by --nsg-rule SSH)..."
az vm open-port --resource-group "$AZ_RG" --name "$AZ_VM_NAME" \
    --port 80 --priority 310 --output none
az vm open-port --resource-group "$AZ_RG" --name "$AZ_VM_NAME" \
    --port 443 --priority 320 --output none

# --- wait for SSH ----------------------------------------------------------

log "Waiting for SSH on $FQDN ..."
# Derive the private key path from the pubkey path (drop trailing .pub).
SSH_KEY="${AZ_SSH_PUBKEY%.pub}"
ssh_ok=0
for _ in $(seq 1 30); do
    if ssh -i "$SSH_KEY" \
           -o BatchMode=yes \
           -o StrictHostKeyChecking=accept-new \
           -o UserKnownHostsFile="$OUT_DIR/known_hosts" \
           -o ConnectTimeout=5 \
           "$AZ_ADMIN_USER@$FQDN" true 2>/dev/null; then
        ssh_ok=1
        break
    fi
    sleep 3
done
[ $ssh_ok -eq 1 ] || die "SSH to $FQDN never came up after ~90s"
log "SSH ready."

# --- persist outputs -------------------------------------------------------

mkdir -p "$OUT_DIR"
jq -n \
    --arg rg "$AZ_RG" \
    --arg vm "$AZ_VM_NAME" \
    --arg location "$AZ_LOCATION" \
    --arg fqdn "$FQDN" \
    --arg public_ip "$PUBLIC_IP" \
    --arg admin_user "$AZ_ADMIN_USER" \
    --arg ssh_key "$SSH_KEY" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{rg:$rg, vm:$vm, location:$location, fqdn:$fqdn, public_ip:$public_ip, admin_user:$admin_user, ssh_key:$ssh_key, created_at:$created_at}' \
    > "$OUT_FILE"

log "Wrote $OUT_FILE:"
cat "$OUT_FILE" >&2
log "Done. Next: just az-configure"
