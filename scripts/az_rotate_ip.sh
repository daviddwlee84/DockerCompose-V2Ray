#!/usr/bin/env bash
# Rotate the Standard SKU public IP attached to an Azure VM, keeping the
# <dns-label>.<region>.cloudapp.azure.com FQDN unchanged.
#
# Use when the current public IP has been GFW-banned. Because the DNS label
# lives on the public-IP resource (not on the IP itself), detaching the PIP,
# deleting it, and re-creating it with the same --dns-name yields a new IP
# from Azure's pool while the FQDN stays stable. Let's Encrypt cert,
# vault_domain, v2ray UUID, and client configs are therefore all unchanged —
# no redeploy, no client reconfiguration.
#
# Runs from the LAPTOP only. Do NOT run on the VPS itself: step 2 (detach)
# kills the public IP before step 5 (reattach) restores it, which would sever
# the running SSH session before the script can finish.
#
# Usage:
#   scripts/az_rotate_ip.sh                # infer RG from .secrets/azure/{vms/current,last-vm.json}
#   scripts/az_rotate_ip.sh <resource-group>
#   AZ_RG=my-rg scripts/az_rotate_ip.sh
#   AZ_YES=1 scripts/az_rotate_ip.sh       # skip confirm prompt

set -euo pipefail

# --- paths -----------------------------------------------------------------

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="$REPO_ROOT/.secrets/azure"
LEGACY_LAST_VM="$OUT_DIR/last-vm.json"
VMS_DIR="$OUT_DIR/vms"

log()  { printf '[az-rotate-ip] %s\n' "$*" >&2; }
die()  { printf '[az-rotate-ip] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[az-rotate-ip] WARN: %s\n' "$*" >&2; }

# --- preflight -------------------------------------------------------------

command -v az >/dev/null || die "az CLI not found on PATH"
command -v jq >/dev/null || die "jq not found on PATH (brew install jq)"

az account show >/dev/null 2>&1 || die "az CLI not logged in — run 'az login' first"

# Refuse to run on the VPS: detach → delete → recreate will sever our own
# SSH session before reattach can happen. SSH_CONNECTION is always set in
# an interactive SSH shell.
if [ -n "${SSH_CONNECTION:-}" ]; then
    die "looks like you're running this over SSH (SSH_CONNECTION=$SSH_CONNECTION). Run from the laptop, not the VPS — detaching the PIP will kill this session."
fi

# --- resolve RG + state file ----------------------------------------------

AZ_RG="${1:-${AZ_RG:-}}"
STATE_FILE=""

list_tracked_rgs() {
    [ -d "$VMS_DIR" ] || return 0
    for f in "$VMS_DIR"/*.json; do
        [ -f "$f" ] && [ "$(basename "$f")" != "current" ] || continue
        jq -r '.rg // empty' "$f" 2>/dev/null
    done | sort -u | grep . || true
}

resolve_state_file() {
    # Explicit RG passed: prefer per-VM state, fall back to legacy if it matches.
    if [ -n "$AZ_RG" ]; then
        if [ -f "$VMS_DIR/$AZ_RG.json" ]; then
            STATE_FILE="$VMS_DIR/$AZ_RG.json"
            return
        fi
        if [ -f "$LEGACY_LAST_VM" ]; then
            local legacy_rg
            legacy_rg=$(jq -r '.rg // empty' "$LEGACY_LAST_VM")
            if [ "$legacy_rg" = "$AZ_RG" ]; then
                STATE_FILE="$LEGACY_LAST_VM"
                return
            fi
        fi
        die "AZ_RG=$AZ_RG is not tracked under $VMS_DIR/ — run 'just az-up' first, or check the name."
    fi

    # No explicit RG: decide based on how many VMs are tracked.
    local rgs count
    rgs=$(list_tracked_rgs)
    count=$(printf '%s\n' "$rgs" | grep -c . || true)

    if [ "$count" -gt 1 ]; then
        log "Multiple VMs tracked — pass the resource group you want to rotate:"
        for rg in $rgs; do
            local fqdn
            fqdn=$(jq -r '.fqdn // empty' "$VMS_DIR/$rg.json" 2>/dev/null)
            printf '  %s (%s)\n' "$rg" "$fqdn" >&2
        done
        die "no RG specified (pass <rg> positionally or set AZ_RG)"
    fi

    if [ "$count" = "1" ]; then
        AZ_RG=$(printf '%s\n' "$rgs" | head -n 1)
        STATE_FILE="$VMS_DIR/$AZ_RG.json"
        return
    fi

    # Zero tracked: legacy last-vm.json (if any) or give up.
    if [ -f "$LEGACY_LAST_VM" ]; then
        AZ_RG=$(jq -r '.rg // empty' "$LEGACY_LAST_VM")
        STATE_FILE="$LEGACY_LAST_VM"
        return
    fi

    die "no VM state found: run 'just az-up' first, or pass a resource group explicitly."
}

resolve_state_file
[ -n "$AZ_RG" ] || die "failed to resolve AZ_RG from $STATE_FILE"

log "Using state file: $STATE_FILE (rg=$AZ_RG)"

# --- discover VM + NIC + PIP ----------------------------------------------

az group show --name "$AZ_RG" >/dev/null 2>&1 || die "resource group '$AZ_RG' does not exist or you don't have access"

VM_NAME=$(jq -r '.vm // empty' "$STATE_FILE")
[ -n "$VM_NAME" ] || die "state file $STATE_FILE missing .vm"

log "Looking up VM '$VM_NAME' in RG '$AZ_RG'..."
VM_NIC_ID=$(az vm show -g "$AZ_RG" -n "$VM_NAME" \
    --query 'networkProfile.networkInterfaces[0].id' -o tsv 2>/dev/null) \
    || die "VM '$VM_NAME' not found in RG '$AZ_RG'"
[ -n "$VM_NIC_ID" ] || die "could not resolve NIC id for VM '$VM_NAME'"

NIC_NAME=$(basename "$VM_NIC_ID")
NIC_JSON=$(az network nic show --ids "$VM_NIC_ID" -o json)
IP_CONFIG_NAME=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].name // empty')
PIP_ID=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].publicIpAddress.id // empty')

[ -n "$IP_CONFIG_NAME" ] || die "could not resolve ip-config name on NIC $NIC_NAME"
[ -n "$PIP_ID" ] || die "NIC $NIC_NAME has no public IP attached — nothing to rotate"

PIP_NAME=$(basename "$PIP_ID")
PIP_JSON=$(az network public-ip show --ids "$PIP_ID" -o json)

PIP_SKU=$(echo "$PIP_JSON" | jq -r '.sku.name // empty')
DNS_LABEL=$(echo "$PIP_JSON" | jq -r '.dnsSettings.domainNameLabel // empty')
PIP_LOCATION=$(echo "$PIP_JSON" | jq -r '.location // empty')
CURRENT_IP=$(echo "$PIP_JSON" | jq -r '.ipAddress // empty')
FQDN=$(echo "$PIP_JSON" | jq -r '.dnsSettings.fqdn // empty')

if [ "$PIP_SKU" != "Standard" ]; then
    die "public IP '$PIP_NAME' is SKU '$PIP_SKU' — this script only supports Standard. Basic SKU was retired 2025-09-30; upgrade first (https://learn.microsoft.com/azure/virtual-network/ip-services/public-ip-upgrade)."
fi

[ -n "$DNS_LABEL" ] || die "public IP '$PIP_NAME' has no DNS label — nothing to preserve across rotation. Aborting; use 'just az-down' + 'just az-up' instead."
[ -n "$PIP_LOCATION" ] || die "could not determine location from PIP"

log "VM:             $VM_NAME"
log "NIC:            $NIC_NAME (ip-config: $IP_CONFIG_NAME)"
log "Public IP:      $PIP_NAME ($CURRENT_IP, sku=$PIP_SKU)"
log "DNS label:      $DNS_LABEL (region-unique within $PIP_LOCATION)"
log "FQDN:           $FQDN"
log ""
log "After rotation: FQDN stays the same, IP changes. Cert / vault / client"
log "configs will NOT need updating. ~30-60s outage during detach/recreate."

if [ "${AZ_YES:-0}" != "1" ]; then
    printf '[az-rotate-ip] Proceed with rotating public IP? [y/N]: ' >&2
    read -r confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) die "aborted by user" ;;
    esac
fi

# --- rotate ----------------------------------------------------------------

log "[1/5] Detaching PIP '$PIP_NAME' from NIC '$NIC_NAME'..."
az network nic ip-config update \
    --resource-group "$AZ_RG" \
    --nic-name "$NIC_NAME" \
    --name "$IP_CONFIG_NAME" \
    --remove PublicIpAddress \
    --output none

log "[2/5] Deleting PIP '$PIP_NAME' (releasing $CURRENT_IP to Azure pool)..."
az network public-ip delete \
    --resource-group "$AZ_RG" \
    --name "$PIP_NAME" \
    --output none

log "[3/5] Recreating PIP '$PIP_NAME' with same dns-name '$DNS_LABEL'..."
az network public-ip create \
    --resource-group "$AZ_RG" \
    --name "$PIP_NAME" \
    --location "$PIP_LOCATION" \
    --sku Standard \
    --allocation-method Static \
    --dns-name "$DNS_LABEL" \
    --output none

log "[4/5] Reattaching PIP to NIC..."
az network nic ip-config update \
    --resource-group "$AZ_RG" \
    --nic-name "$NIC_NAME" \
    --name "$IP_CONFIG_NAME" \
    --public-ip-address "$PIP_NAME" \
    --output none

NEW_IP=$(az network public-ip show \
    --resource-group "$AZ_RG" \
    --name "$PIP_NAME" \
    --query ipAddress -o tsv)
[ -n "$NEW_IP" ] || die "failed to read new IP from recreated PIP"

log "[5/5] New public IP: $NEW_IP (was $CURRENT_IP)"

# --- update state file -----------------------------------------------------

TMP=$(mktemp)
jq --arg ip "$NEW_IP" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.public_ip = $ip | .rotated_at = $at' \
    "$STATE_FILE" > "$TMP"
mv "$TMP" "$STATE_FILE"
log "Updated $STATE_FILE (public_ip, rotated_at)"

# --- verify DNS ------------------------------------------------------------

if command -v dig >/dev/null 2>&1 && [ -n "$FQDN" ]; then
    log "Verifying DNS (dig +short $FQDN)..."
    resolved=""
    for _ in $(seq 1 10); do
        resolved=$(dig +short "$FQDN" @8.8.8.8 2>/dev/null | tail -n 1 || true)
        if [ "$resolved" = "$NEW_IP" ]; then
            log "DNS now resolves to $NEW_IP (Azure DNS caught up)."
            break
        fi
        sleep 3
    done
    if [ "$resolved" != "$NEW_IP" ]; then
        warn "DNS still resolves to '$resolved' (expected '$NEW_IP'). Usually <30s to propagate; re-run 'dig +short $FQDN' in a minute."
    fi
else
    log "(dig not on PATH — skipping DNS verification; confirm with 'nslookup $FQDN')"
fi

log ""
log "Done. FQDN / cert / v2ray UUID are unchanged — no client reconfiguration needed."
log "If clients still see the old IP, flush local DNS cache or wait for TTL."
