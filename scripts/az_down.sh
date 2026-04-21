#!/usr/bin/env bash
# Tear down the Azure RG tracked in .secrets/azure/last-vm.json.
#
# Usage:
#   scripts/az_down.sh           # interactive confirm
#   scripts/az_down.sh -y        # no confirm (cycle / CI use)
#   AZ_RG=explicit-rg scripts/az_down.sh -y
#
# Leaves .secrets/.vault-pass in place (re-usable across runs); you can delete
# it manually if you want a fresh vault password on the next az-cycle.

set -euo pipefail

OUT_FILE=".secrets/azure/last-vm.json"
YES=0
KEEP_KEYS=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=1 ;;
        --keep-keys) KEEP_KEYS=1 ;;
        -h|--help)
            sed -n '2,10p' "$0"
            exit 0
            ;;
        *) printf '[az-down] unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

log() { printf '[az-down] %s\n' "$*" >&2; }
die() { printf '[az-down] ERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "az CLI not found on PATH"

SSH_KEY_DIR=""
if [ -z "${AZ_RG:-}" ]; then
    [ -f "$OUT_FILE" ] || die "$OUT_FILE not found — pass AZ_RG=<rg> explicitly"
    if command -v jq >/dev/null 2>&1; then
        AZ_RG=$(jq -r '.rg // empty' "$OUT_FILE")
        SSH_KEY_DIR=$(jq -r '.ssh_key_dir // empty' "$OUT_FILE")
    else
        AZ_RG=$(awk -F'"' '/"rg"/{print $4; exit}' "$OUT_FILE")
    fi
    [ -n "$AZ_RG" ] || die "failed to parse 'rg' from $OUT_FILE"
fi

if ! az group show --name "$AZ_RG" >/dev/null 2>&1; then
    log "Resource group $AZ_RG does not exist (already torn down?)"
    rm -f "$OUT_FILE"
    log "Cleared $OUT_FILE."
    exit 0
fi

log "About to delete resource group: $AZ_RG"
log "Subscription: $(az account show --query name -o tsv)"
az resource list --resource-group "$AZ_RG" --query '[].{name:name,type:type}' -o table >&2 || true

if [ $YES -ne 1 ]; then
    printf '[az-down] Type the RG name to confirm: ' >&2
    read -r confirm
    [ "$confirm" = "$AZ_RG" ] || die "confirmation mismatch — aborting"
fi

log "Deleting (--no-wait; Azure will reap in the background)..."
az group delete --name "$AZ_RG" --yes --no-wait

rm -f "$OUT_FILE"
log "Cleared $OUT_FILE."

# Reap the per-RG SSH key dir too (az_up.sh auto-generates one unless the
# caller set AZ_SSH_PUBKEY; that dir is bound to the VM we just deleted).
# Pass --keep-keys to preserve it for forensics / reconnect after a failure.
if [ $KEEP_KEYS -ne 1 ] && [ -n "$SSH_KEY_DIR" ] && [ -d "$SSH_KEY_DIR" ]; then
    log "Removing per-RG SSH key dir $SSH_KEY_DIR (pass --keep-keys to preserve)"
    rm -rf "$SSH_KEY_DIR"
fi

log "Done. Check status with: az group show --name $AZ_RG"
