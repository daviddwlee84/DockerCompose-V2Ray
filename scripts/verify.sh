#!/bin/bash
# Smoke test the deployed VPN server.
#
# Usage:
#   ./scripts/verify.sh <rg>                        # positional
#   ./scripts/verify.sh --rg <rg>                   # long flag
#   RG=<rg>             ./scripts/verify.sh         # env var
#   DOMAIN=your.tld     ./scripts/verify.sh         # explicit domain (skips RG lookup)
#
# With multiple VMs tracked under .secrets/azure/vms/, run the script once
# per RG (or set DOMAIN manually). Example multi-VM loop:
#   for f in .secrets/azure/vms/*.json; do
#     [ "$(basename "$f")" = current ] && continue
#     DOMAIN=$(jq -r .fqdn "$f") ./scripts/verify.sh || echo "  (failed: $f)"
#   done

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VMS_DIR="$REPO_ROOT/.secrets/azure/vms"
LEGACY_LAST_VM="$REPO_ROOT/.secrets/azure/last-vm.json"

# Arg parse: accept <rg> positional or --rg <rg>; merge with RG= env var.
POSITIONAL=""
FLAG_RG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rg)
            shift
            [ $# -gt 0 ] || { echo "verify.sh: --rg requires an argument" >&2; exit 2; }
            FLAG_RG="$1"
            ;;
        --rg=*) FLAG_RG="${1#--rg=}" ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        -*) echo "verify.sh: unknown flag: $1" >&2; exit 2 ;;
        *)
            [ -z "$POSITIONAL" ] || { echo "verify.sh: multiple RG arguments: $POSITIONAL, $1" >&2; exit 2; }
            POSITIONAL="$1"
            ;;
    esac
    shift
done

if [ -n "$POSITIONAL" ] && [ -n "$FLAG_RG" ] && [ "$POSITIONAL" != "$FLAG_RG" ]; then
    echo "verify.sh: conflicting resource groups: positional=$POSITIONAL, --rg=$FLAG_RG" >&2
    exit 2
fi
RG="${POSITIONAL:-${FLAG_RG:-${RG:-}}}"

# Resolve DOMAIN from RG (positional, --rg, or RG= env) if not already set.
if [ -z "${DOMAIN:-}" ] && [ -n "${RG:-}" ]; then
    state="$VMS_DIR/$RG.json"
    if [ ! -f "$state" ]; then
        echo "verify.sh: RG=$RG but $state not found" >&2
        exit 1
    fi
    DOMAIN=$(jq -r '.fqdn // empty' "$state")
    [ -n "$DOMAIN" ] || { echo "verify.sh: could not read .fqdn from $state" >&2; exit 1; }
fi

# Zero-arg convenience: if exactly one VM is tracked, use its FQDN. Refuse
# when more than one is tracked — silent defaults are a footgun.
if [ -z "${DOMAIN:-}" ] && [ -d "$VMS_DIR" ]; then
    shopt -s nullglob
    tracked=("$VMS_DIR"/*.json)
    shopt -u nullglob
    if [ "${#tracked[@]}" -gt 0 ]; then
        unique_rgs=$(for f in "${tracked[@]}"; do
            [ "$(basename "$f")" = current ] && continue
            jq -r '.rg // empty' "$f" 2>/dev/null
        done | sort -u)
        count=$(printf '%s\n' "$unique_rgs" | grep -c . || true)
        if [ "$count" = "1" ]; then
            one=$(printf '%s\n' "$unique_rgs" | head -n 1)
            DOMAIN=$(jq -r '.fqdn // empty' "$VMS_DIR/$one.json")
        elif [ "$count" -gt 1 ]; then
            echo "verify.sh: multiple VMs tracked — pass RG=<rg> or DOMAIN=<fqdn>:" >&2
            for rg in $unique_rgs; do
                fqdn=$(jq -r '.fqdn // empty' "$VMS_DIR/$rg.json" 2>/dev/null)
                printf '  %s (%s)\n' "$rg" "$fqdn" >&2
            done
            exit 1
        fi
    fi
fi

if [ -z "${DOMAIN:-}" ] && [ -f "$LEGACY_LAST_VM" ]; then
    DOMAIN=$(jq -r '.fqdn // empty' "$LEGACY_LAST_VM" 2>/dev/null || true)
fi

: "${DOMAIN:?DOMAIN must be set, e.g. DOMAIN=your-host.japaneast.cloudapp.azure.com}"

fail=0

check() {
    local label="$1"
    local cmd="$2"
    local expect="$3"
    local got
    got=$(eval "$cmd" 2>/dev/null || true)
    if [[ "$got" == *"$expect"* ]]; then
        printf "  ok   %-40s -> %s\n" "$label" "$got"
    else
        printf "  FAIL %-40s -> %s (expected substring: %s)\n" "$label" "$got" "$expect"
        fail=1
    fi
}

echo "Smoke testing https://$DOMAIN ..."

# Root: should 200 with the landing page.
check "landing page" \
    "curl -sS -o /dev/null -w '%{http_code}' https://$DOMAIN/" \
    "200"

# /v2ray: should 400 bad request (V2Ray receives a non-WebSocket GET and rejects it).
# A 502 here means V2Ray is not running or nginx can't reach it.
check "V2Ray WS endpoint reachable" \
    "curl -sS -o /dev/null -w '%{http_code}' https://$DOMAIN/v2ray" \
    "400"

# TLS cert should be valid (not self-signed, not expired).
check "TLS cert chain valid" \
    "echo | openssl s_client -servername $DOMAIN -connect $DOMAIN:443 2>&1 | grep -c 'Verify return code: 0'" \
    "1"

if [[ $fail -eq 0 ]]; then
    echo "All smoke checks passed."
    exit 0
else
    echo "Smoke checks failed. Investigate logs:"
    echo "  ansible vpn -a 'tail -n 100 /opt/vpn/runtime/logs/nginx/error.log'"
    echo "  ansible vpn -a 'tail -n 100 /opt/vpn/runtime/logs/v2ray/error.log'"
    exit 1
fi
