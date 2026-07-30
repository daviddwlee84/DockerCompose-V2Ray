#!/bin/bash
# Smoke test the deployed VPN server.
#
# What it checks depends on `vpn_protocol` in ansible/group_vars/all.yml,
# because the three modes put completely different things on port 443:
#
#   reality   443 is Xray. There is no certificate of ours to inspect — the
#             proof is the opposite: a handshake with the BORROWED SNI must
#             return the real dest site's valid certificate, and a handshake
#             with our own hostname must NOT return a Let's Encrypt cert for it.
#   vmess_ws  443 is nginx with our LE cert (the pre-2026-07 checks).
#   both      REALITY on 443 plus the legacy WS listener on vmess_ws_port.
#
# All of this only proves the front door looks right. It cannot prove traffic
# flows — for that, `just verify-proxy` dials the node with a real client.
#
# Usage:
#   ./scripts/verify.sh <rg>                        # positional
#   ./scripts/verify.sh --rg <rg>                   # long flag
#   RG=<rg>             ./scripts/verify.sh         # env var
#   DOMAIN=your.tld     ./scripts/verify.sh         # explicit domain (skips RG lookup)
#   PROTOCOL=reality    ./scripts/verify.sh         # override the detected mode
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
ALL_VARS="$REPO_ROOT/ansible/group_vars/all.yml"

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
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
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

# --- Read the deployed shape out of group_vars ---------------------------
# Deliberately grep rather than parse: the system python3 has no PyYAML, and
# these are simple top-level scalars in a file this repo controls.
yaml_scalar() {  # yaml_scalar <key> <default>
    local v
    v=$(sed -n "s/^$1:[[:space:]]*//p" "$ALL_VARS" 2>/dev/null | head -1 | tr -d '"'"'" | sed 's/[[:space:]]*#.*//')
    printf '%s' "${v:-$2}"
}
yaml_first_list_item() {  # yaml_first_list_item <key> <default>
    local v
    v=$(awk -v k="$1:" '
        $0 ~ "^"k"$" {f=1; next}
        f && /^[[:space:]]*-[[:space:]]*/ {sub(/^[[:space:]]*-[[:space:]]*/,""); gsub(/"/,""); print; exit}
        f && /^[^[:space:]-]/ {exit}
    ' "$ALL_VARS" 2>/dev/null)
    printf '%s' "${v:-$2}"
}

PROTOCOL="${PROTOCOL:-$(yaml_scalar vpn_protocol reality)}"
WS_PATH="${WS_PATH:-$(yaml_scalar v2ray_ws_path /v2ray)}"
VMESS_WS_PORT="${VMESS_WS_PORT:-$(yaml_scalar vmess_ws_port 2053)}"
REALITY_SNI="${REALITY_SNI:-$(yaml_first_list_item reality_server_names www.apple.com)}"
# Apex of the borrowed SNI, so a wildcard or bare-apex certificate still matches.
SNI_APEX=$(printf '%s' "$REALITY_SNI" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}')

case "$PROTOCOL" in
    reality|vmess_ws|both) ;;
    *) echo "verify.sh: unknown vpn_protocol '$PROTOCOL' (expected reality|vmess_ws|both)" >&2; exit 2 ;;
esac

fail=0

check() {
    local label="$1" cmd="$2" expect="$3" got
    got=$(eval "$cmd" 2>/dev/null || true)
    if [[ "$got" == *"$expect"* ]]; then
        printf "  ok   %-40s -> %s\n" "$label" "$got"
    else
        printf "  FAIL %-40s -> %s (expected substring: %s)\n" "$label" "$got" "$expect"
        fail=1
    fi
}

check_absent() {
    local label="$1" cmd="$2" forbidden="$3" got
    got=$(eval "$cmd" 2>/dev/null || true)
    if [[ "$got" == *"$forbidden"* ]]; then
        printf "  FAIL %-40s -> %s (must NOT contain: %s)\n" "$label" "$got" "$forbidden"
        fail=1
    else
        printf "  ok   %-40s -> %s\n" "$label" "${got:-<no match>}"
    fi
}

# check/check_absent take a command STRING (they eval it), so these helpers
# emit commands rather than running them.
peer_subject() {  # peer_subject <sni> <host:port>
    echo "echo | openssl s_client -servername '$1' -connect '$2' 2>/dev/null | grep -m1 '^subject=' || echo '<no certificate>'"
}

tls_verify_ok() {  # tls_verify_ok <sni> <host:port>
    echo "echo | openssl s_client -servername '$1' -connect '$2' 2>&1 | grep -c 'Verify return code: 0'"
}

echo "Smoke testing $DOMAIN (vpn_protocol: $PROTOCOL) ..."

if [ "$PROTOCOL" = "reality" ] || [ "$PROTOCOL" = "both" ]; then
    # nginx keeps port 80 for the landing page; there is no HTTPS redirect in
    # these modes because 443 is not ours to redirect to.
    check "landing page (http :80)" \
        "curl -sS -o /dev/null -w '%{http_code}' http://$DOMAIN/" \
        "200"

    # The real REALITY proof: handshake with the borrowed SNI has to come back
    # with the dest site's genuine, publicly-trusted certificate.
    check "REALITY borrows a valid cert chain" \
        "$(tls_verify_ok "$REALITY_SNI" "$DOMAIN:443")" \
        "1"

    check "REALITY presents $SNI_APEX cert" \
        "$(peer_subject "$REALITY_SNI" "$DOMAIN:443")" \
        "$SNI_APEX"

    # And the inverse: our own hostname must not yield a certificate issued to
    # us. If it does, an old nginx TLS listener is still squatting on 443.
    check_absent "no own-cert leak on :443" \
        "$(peer_subject "$DOMAIN" "$DOMAIN:443")" \
        "$DOMAIN"
fi

if [ "$PROTOCOL" = "vmess_ws" ] || [ "$PROTOCOL" = "both" ]; then
    if [ "$PROTOCOL" = "vmess_ws" ]; then
        ws_base="https://$DOMAIN"
        ws_hostport="$DOMAIN:443"
    else
        ws_base="https://$DOMAIN:$VMESS_WS_PORT"
        ws_hostport="$DOMAIN:$VMESS_WS_PORT"
    fi

    check "landing page ($ws_base)" \
        "curl -sS -o /dev/null -w '%{http_code}' $ws_base/" \
        "200"

    # 400 = Xray received a non-WebSocket GET on the WS path and rejected it.
    # A 502 here means Xray is down or nginx can't reach it.
    check "WS endpoint reachable ($WS_PATH)" \
        "curl -sS -o /dev/null -w '%{http_code}' $ws_base$WS_PATH" \
        "400"

    check "TLS cert chain valid ($ws_hostport)" \
        "$(tls_verify_ok "$DOMAIN" "$ws_hostport")" \
        "1"
fi

if [[ $fail -eq 0 ]]; then
    echo "All smoke checks passed."
    if [ "$PROTOCOL" != "vmess_ws" ]; then
        echo "Note: this only proves the front door. Run 'just verify-proxy' to prove traffic flows."
    fi
    exit 0
else
    echo "Smoke checks failed. Investigate logs:"
    echo "  ansible vpn -a 'tail -n 100 /opt/vpn/runtime/logs/nginx/error.log'"
    echo "  ansible vpn -a 'docker logs --tail 100 xray'"
    exit 1
fi
