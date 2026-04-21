#!/usr/bin/env bash
# Provision a throwaway Azure VM for end-to-end validation of the V2Ray deploy.
#
# Requires: az CLI (already logged in, `az account show` should work), jq,
# curl (for the live-pricing lookup; silently skipped if unavailable).
# Writes:   .secrets/azure/last-vm.json with everything the rest of the flow needs.
#
# All inputs are env vars with sensible defaults. Override any of them inline:
#   AZ_LOCATION=eastasia AZ_VM_SIZE=Standard_B1s scripts/az_up.sh
#
# Non-obvious env vars:
#   AZ_SSH_PUBKEY    Reuse an existing pubkey instead of minting a fresh one.
#                    Default: generate a per-RG ed25519 keypair under
#                    .secrets/azure/<rg>/id_ed25519(.pub). az_down.sh removes
#                    the directory on teardown.
#   AZ_SHUTDOWN_TIME Daily auto-shutdown time in UTC HHMM (Azure DevTest Labs
#                    schedule). Default: 1800 (= 02:00 Asia/Shanghai, 03:00
#                    Asia/Tokyo). Set to 'off' to disable.
#   AZ_YES           Skip the "estimated cost, proceed?" confirm prompt.
#   AZ_OVERWRITE     Clobber an existing last-vm.json (orphans the prior VM).

set -euo pipefail

# --- inputs ----------------------------------------------------------------

: "${AZ_LOCATION:=japaneast}"
: "${AZ_VM_NAME:=vpn}"
: "${AZ_VM_SIZE:=Standard_B2ats_v2}"
# Use the full URN; the 'Ubuntu2404' alias has intermittent parsing bugs in
# az CLI 2.85 (ERROR: Extra data: line 1 column 4). Stick to the URN.
: "${AZ_IMAGE:=Canonical:ubuntu-24_04-lts:server:latest}"
: "${AZ_ADMIN_USER:=azureuser}"
: "${AZ_SHUTDOWN_TIME:=off}"

# Generated defaults (only if caller didn't pre-set them).
if [ -z "${AZ_RG:-}" ]; then
    AZ_RG="vpn-test-$(whoami | tr -cd '[:alnum:]')-$(date +%s)"
fi
if [ -z "${AZ_DNS_PREFIX:-}" ]; then
    AZ_DNS_PREFIX="vpn-$(openssl rand -hex 4)"
fi

OUT_DIR=".secrets/azure"
OUT_FILE="$OUT_DIR/last-vm.json"
KEY_DIR="$OUT_DIR/$AZ_RG"

# --- preflight -------------------------------------------------------------

log() { printf '[az-up] %s\n' "$*" >&2; }
die() { printf '[az-up] ERROR: %s\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "az CLI not found on PATH"
command -v jq >/dev/null || die "jq not found on PATH (brew install jq)"

az account show >/dev/null 2>&1 || die "az CLI not logged in — run 'az login' first"

# SSH key selection:
#   - If AZ_SSH_PUBKEY is set, honour it verbatim (user wants to reuse a key).
#   - Otherwise mint a fresh per-RG keypair under .secrets/azure/<rg>/.
#     Keeping the key isolated per throwaway VM means a leak on one probe
#     can't be replayed against another, and az_down.sh can safely wipe it.
if [ -n "${AZ_SSH_PUBKEY:-}" ]; then
    [ -f "$AZ_SSH_PUBKEY" ] || die "AZ_SSH_PUBKEY points at $AZ_SSH_PUBKEY, which does not exist"
    log "Using caller-supplied SSH pubkey: $AZ_SSH_PUBKEY"
    SSH_KEY_AUTO_GENERATED=0
else
    mkdir -p "$KEY_DIR"
    chmod 700 "$KEY_DIR"
    if [ ! -f "$KEY_DIR/id_ed25519" ]; then
        log "Generating fresh ed25519 keypair under $KEY_DIR/ ..."
        ssh-keygen -t ed25519 -N '' -f "$KEY_DIR/id_ed25519" -C "vpn-$AZ_RG" >/dev/null
    else
        log "Reusing existing keypair under $KEY_DIR/ (delete that dir to regenerate)"
    fi
    AZ_SSH_PUBKEY="$PWD/$KEY_DIR/id_ed25519.pub"
    SSH_KEY_AUTO_GENERATED=1
fi

# Guard against stale state: if last-vm.json already exists, refuse unless
# caller explicitly asked to overwrite. Prevents accidentally orphaning a VM.
if [ -f "$OUT_FILE" ] && [ "${AZ_OVERWRITE:-0}" != "1" ]; then
    die "$OUT_FILE already exists. Run 'just az-down' first, or set AZ_OVERWRITE=1 to clobber (this will ORPHAN the previously-tracked VM)."
fi

# --- cost preview + confirm ------------------------------------------------

# Best-effort query of the Azure Retail Prices API for the target (location,
# sku). No auth required. Falls through silently on timeout / parse error;
# we still link the user at the portal pricing page in that case.
estimate_price_per_hour() {
    local location="$1" sku="$2" json url
    url="https://prices.azure.com/api/retail/prices?\$filter=armRegionName%20eq%20'${location}'%20and%20armSkuName%20eq%20'${sku}'%20and%20priceType%20eq%20'Consumption'%20and%20serviceName%20eq%20'Virtual%20Machines'"
    command -v curl >/dev/null || return 1
    json=$(curl -fsS --max-time 5 "$url" 2>/dev/null) || return 1
    # Cheapest Linux consumption price — reject Windows, Spot, and Low Priority.
    echo "$json" | jq -er '
        [ .Items[]
          | select((.productName // "") | test("Windows") | not)
          | select((.skuName // "") | test("Spot"; "i") | not)
          | select((.skuName // "") | test("Low Priority"; "i") | not)
          | .retailPrice
        ] | min
    ' 2>/dev/null
}

log "Subscription:       $(az account show --query name -o tsv)"
log "Resource group:     $AZ_RG ($AZ_LOCATION)"
log "VM:                 $AZ_VM_NAME ($AZ_VM_SIZE, $AZ_IMAGE)"
log "DNS prefix:         $AZ_DNS_PREFIX"
log "SSH pubkey:         $AZ_SSH_PUBKEY"
if [ "$AZ_SHUTDOWN_TIME" = "off" ]; then
    log "Auto-shutdown:      DISABLED (AZ_SHUTDOWN_TIME=off)"
else
    log "Auto-shutdown:      ${AZ_SHUTDOWN_TIME} UTC daily (set AZ_SHUTDOWN_TIME=off to disable)"
fi

log "Looking up retail pricing for $AZ_VM_SIZE in $AZ_LOCATION ..."
if price=$(estimate_price_per_hour "$AZ_LOCATION" "$AZ_VM_SIZE") && [ "$price" != "null" ] && [ -n "$price" ]; then
    daily=$(awk -v p="$price" 'BEGIN{printf "%.2f", p*24}')
    monthly=$(awk -v p="$price" 'BEGIN{printf "%.2f", p*730}')
    log "Estimated compute:  \$${price}/hour  (~\$${daily}/day, ~\$${monthly}/month, Linux PAYG)"
    log "(Plus ~\$3/mo for the Standard public IP and ~\$0.005/GB egress.)"
else
    log "Could not fetch live pricing — see:"
    log "  https://azure.microsoft.com/pricing/details/virtual-machines/linux/"
fi

if [ "${AZ_YES:-0}" != "1" ]; then
    printf '[az-up] Proceed with provisioning? [y/N]: ' >&2
    read -r confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) die "aborted by user" ;;
    esac
fi

# --- provision -------------------------------------------------------------

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

# Safety net for forgotten VMs. Uses the built-in DevTest Labs auto-shutdown
# schedule, so it keeps running even if az_down.sh never gets called.
if [ "$AZ_SHUTDOWN_TIME" != "off" ]; then
    log "Configuring auto-shutdown at ${AZ_SHUTDOWN_TIME} UTC daily..."
    if ! az vm auto-shutdown --resource-group "$AZ_RG" --name "$AZ_VM_NAME" \
            --time "$AZ_SHUTDOWN_TIME" --output none 2>/dev/null; then
        log "(warning: auto-shutdown setup failed — set AZ_SHUTDOWN_TIME=off to silence)"
    fi
fi

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
    --arg ssh_key_dir "$([ "$SSH_KEY_AUTO_GENERATED" = "1" ] && printf '%s' "$KEY_DIR" || printf '')" \
    --arg shutdown_time "$AZ_SHUTDOWN_TIME" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{rg:$rg, vm:$vm, location:$location, fqdn:$fqdn, public_ip:$public_ip,
      admin_user:$admin_user, ssh_key:$ssh_key, ssh_key_dir:$ssh_key_dir,
      shutdown_time:$shutdown_time, created_at:$created_at}' \
    > "$OUT_FILE"

log "Wrote $OUT_FILE:"
cat "$OUT_FILE" >&2

# --- hint: ~/.ssh/config snippet ------------------------------------------

if [ "$SSH_KEY_AUTO_GENERATED" = "1" ]; then
    cat >&2 <<EOF

[az-up] Tip — drop this into ~/.ssh/config for a short SSH alias:

    Host $AZ_VM_NAME-$AZ_RG
        HostName $FQDN
        User $AZ_ADMIN_USER
        IdentityFile $SSH_KEY
        IdentitiesOnly yes
        UserKnownHostsFile $PWD/$OUT_DIR/known_hosts
        StrictHostKeyChecking accept-new

Then: ssh $AZ_VM_NAME-$AZ_RG
EOF
fi

log "Done. Next: just az-configure"
