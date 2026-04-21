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
for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=1 ;;
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

if [ -z "${AZ_RG:-}" ]; then
    [ -f "$OUT_FILE" ] || die "$OUT_FILE not found — pass AZ_RG=<rg> explicitly"
    AZ_RG=$(awk -F'"' '/"rg"/{print $4; exit}' "$OUT_FILE")
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
log "Cleared $OUT_FILE. Done."
log "Check status with: az group show --name $AZ_RG"
