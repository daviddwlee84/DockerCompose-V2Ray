#!/usr/bin/env bash
# Tear down an Azure RG tracked in .secrets/azure/vms/<rg>.json.
#
# Usage:
#   scripts/az_down.sh                     # tear down vms/current (fails if >1 VM and no current)
#   scripts/az_down.sh <rg>                # tear down a specific RG
#   scripts/az_down.sh -y                  # no confirm (cycle / CI use)
#   scripts/az_down.sh <rg> -y --keep-keys # tear down RG, keep per-RG SSH key dir
#   AZ_RG=explicit-rg scripts/az_down.sh -y
#
# State layout reminder (see az_up.sh header):
#   .secrets/azure/vms/<rg>.json  per-VM handoff
#   .secrets/azure/vms/current    symlink to the most recent vms/<rg>.json
#   .secrets/azure/last-vm.json   legacy mirror (kept while older readers migrate)

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR="$REPO_ROOT/.secrets/azure"
VMS_DIR="$OUT_DIR/vms"
VMS_CURRENT="$VMS_DIR/current"
LEGACY_LAST_VM="$OUT_DIR/last-vm.json"
HOST_VARS_DIR="$REPO_ROOT/ansible/host_vars"

YES=0
KEEP_KEYS=0
POSITIONAL=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes) YES=1 ;;
        --keep-keys) KEEP_KEYS=1 ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        -*) printf '[az-down] unknown flag: %s\n' "$arg" >&2; exit 2 ;;
        *)
            [ -z "$POSITIONAL" ] || { printf '[az-down] multiple RG arguments: %s, %s\n' "$POSITIONAL" "$arg" >&2; exit 2; }
            POSITIONAL="$arg"
            ;;
    esac
done

log() { printf '[az-down] %s\n' "$*" >&2; }
die() { printf '[az-down] ERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "az CLI not found on PATH"

# --- resolve which RG to tear down ----------------------------------------

# Count how many VMs are tracked in vms/ (excluding the 'current' symlink).
tracked_count=0
if [ -d "$VMS_DIR" ]; then
    if command -v jq >/dev/null 2>&1; then
        tracked_count=$(for f in "$VMS_DIR"/*.json; do
            [ -f "$f" ] && [ "$(basename "$f")" != "current" ] || continue
            jq -r '.rg // empty' "$f" 2>/dev/null
        done | sort -u | grep -c . || true)
    fi
fi

STATE_FILE=""
if [ -n "$POSITIONAL" ]; then
    AZ_RG="$POSITIONAL"
elif [ -n "${AZ_RG:-}" ]; then
    :
elif [ "$tracked_count" -gt 1 ]; then
    # Multiple VMs and no explicit choice: refuse. Silently defaulting to
    # vms/current (whichever was last created) is a footgun — the operator
    # almost certainly meant a specific node.
    log "Multiple VMs tracked — pass the resource group you want to delete:"
    for f in "$VMS_DIR"/*.json; do
        [ -f "$f" ] && [ "$(basename "$f")" != "current" ] || continue
        rg=$(jq -r '.rg // empty' "$f")
        fqdn=$(jq -r '.fqdn // empty' "$f")
        printf '  %s (%s)\n' "$rg" "$fqdn" >&2
    done
    die "no RG specified (pass <rg> positionally or set AZ_RG)"
elif [ -L "$VMS_CURRENT" ] || [ -f "$VMS_CURRENT" ]; then
    target=$(readlink "$VMS_CURRENT" 2>/dev/null || true)
    [ -n "$target" ] || die "$VMS_CURRENT exists but isn't a symlink — remove it manually"
    STATE_FILE="$VMS_DIR/$target"
    [ -f "$STATE_FILE" ] || die "vms/current → $target, but $STATE_FILE is missing"
    AZ_RG=$(jq -r '.rg // empty' "$STATE_FILE")
elif [ -f "$LEGACY_LAST_VM" ]; then
    # Legacy single-VM layout: read rg from last-vm.json.
    if command -v jq >/dev/null 2>&1; then
        AZ_RG=$(jq -r '.rg // empty' "$LEGACY_LAST_VM")
    else
        AZ_RG=$(awk -F'"' '/"rg"/{print $4; exit}' "$LEGACY_LAST_VM")
    fi
    STATE_FILE="$LEGACY_LAST_VM"
    [ -n "$AZ_RG" ] || die "failed to parse 'rg' from $LEGACY_LAST_VM"
else
    # Multiple VMs and no 'current' selected: list them and bail.
    if [ -d "$VMS_DIR" ] && compgen -G "$VMS_DIR/*.json" >/dev/null; then
        log "Multiple VMs tracked — pass a resource group to tear down:"
        for f in "$VMS_DIR"/*.json; do
            rg=$(jq -r '.rg // empty' "$f")
            fqdn=$(jq -r '.fqdn // empty' "$f")
            printf '  %s (%s)\n' "$rg" "$fqdn" >&2
        done
        die "no RG specified"
    fi
    die "no VM state found under $VMS_DIR/ or $LEGACY_LAST_VM"
fi

# Resolve state file for the chosen RG if we didn't pick it above.
if [ -z "$STATE_FILE" ]; then
    if [ -f "$VMS_DIR/$AZ_RG.json" ]; then
        STATE_FILE="$VMS_DIR/$AZ_RG.json"
    elif [ -f "$LEGACY_LAST_VM" ] && [ "$(jq -r '.rg // empty' "$LEGACY_LAST_VM")" = "$AZ_RG" ]; then
        STATE_FILE="$LEGACY_LAST_VM"
    fi
    # STATE_FILE may still be empty if the user passed an explicit RG that
    # isn't tracked locally; we'll still delete the RG in Azure but skip
    # the local state cleanup.
fi

SSH_KEY_DIR=""
if [ -n "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
    SSH_KEY_DIR=$(jq -r '.ssh_key_dir // empty' "$STATE_FILE")
fi

# --- confirm + delete -----------------------------------------------------

if ! az group show --name "$AZ_RG" >/dev/null 2>&1; then
    log "Resource group $AZ_RG does not exist (already torn down?)"
else
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
fi

# --- local state cleanup --------------------------------------------------

# Remove the per-VM state file.
if [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    log "Removed $(printf '%s' "$STATE_FILE" | sed "s|$REPO_ROOT/||")."
fi

# Also scrub the legacy mirror if it pointed at the VM we just deleted.
if [ -f "$LEGACY_LAST_VM" ]; then
    legacy_rg=$(jq -r '.rg // empty' "$LEGACY_LAST_VM" 2>/dev/null || true)
    if [ "$legacy_rg" = "$AZ_RG" ]; then
        rm -f "$LEGACY_LAST_VM"
        log "Removed legacy last-vm.json (matched $AZ_RG)."
    fi
fi

# Update vms/current: if it pointed at the RG we just deleted, re-point at
# the most recent surviving vms/*.json, or remove if none remain.
if [ -L "$VMS_CURRENT" ]; then
    current_target=$(readlink "$VMS_CURRENT" 2>/dev/null || true)
    if [ "$current_target" = "$AZ_RG.json" ]; then
        next=""
        if compgen -G "$VMS_DIR/*.json" >/dev/null; then
            # Pick the most-recently-modified remaining state file.
            next=$(ls -t "$VMS_DIR"/*.json 2>/dev/null | head -n 1 | xargs -I{} basename {} || true)
        fi
        if [ -n "$next" ]; then
            ln -sfn "$next" "$VMS_CURRENT"
            log "vms/current → $next (previous was $AZ_RG.json)"
            # Refresh the legacy mirror to match the new 'current'.
            cp "$VMS_DIR/$next" "$LEGACY_LAST_VM"
        else
            rm -f "$VMS_CURRENT"
            log "Removed vms/current (no tracked VMs remain)."
        fi
    fi
fi

# Per-host vault under ansible/host_vars/<rg>/.
if [ -n "${AZ_RG:-}" ] && [ -d "$HOST_VARS_DIR/$AZ_RG" ]; then
    rm -rf -- "${HOST_VARS_DIR:?}/${AZ_RG:?}"
    log "Removed ansible/host_vars/$AZ_RG/."
fi

# Per-RG SSH keys (az_up.sh auto-generates one unless the caller set
# AZ_SSH_PUBKEY; that dir is bound to the VM we just deleted).
# Pass --keep-keys to preserve it for forensics / reconnect after a failure.
if [ $KEEP_KEYS -ne 1 ] && [ -n "$SSH_KEY_DIR" ] && [ -d "$SSH_KEY_DIR" ]; then
    log "Removing per-RG SSH key dir $SSH_KEY_DIR (pass --keep-keys to preserve)"
    rm -rf "$SSH_KEY_DIR"
fi

log "Done. Check status with: az group show --name $AZ_RG"
