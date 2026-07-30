#!/bin/bash
# End-to-end proof that the tunnel actually carries traffic.
#
# scripts/verify.sh only inspects the front door — with REALITY that means
# confirming the server hands back somebody else's certificate, which says
# nothing about whether YOUR uuid/key can get a packet out. This runs a real
# Xray client against out/client/xray-client.json, sends traffic through it,
# and checks that the egress IP is the VPS.
#
# Requires: docker running locally, and `just az-client` already run.
#
# Usage:
#   ./scripts/verify_proxy.sh                  # uses out/client/xray-client.json
#   ./scripts/verify_proxy.sh <rg>             # uses out/client/<rg>/xray-client.json
#   CONFIG=path/to/xray-client.json ./scripts/verify_proxy.sh
#   SOCKS_PORT=10808 ./scripts/verify_proxy.sh

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ALL_VARS="$REPO_ROOT/ansible/group_vars/all.yml"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CONTAINER="vpn-verify-client-$$"

XRAY_IMAGE="${XRAY_IMAGE:-$(sed -n 's/^xray_image:[[:space:]]*//p' "$ALL_VARS" 2>/dev/null | head -1 | tr -d '"' | sed 's/[[:space:]]*#.*//')}"
XRAY_IMAGE="${XRAY_IMAGE:-ghcr.io/xtls/xray-core:26.3.27}"

RG="${1:-${RG:-}}"
if [ -n "${CONFIG:-}" ]; then
    :
elif [ -n "$RG" ] && [ -f "$REPO_ROOT/out/client/$RG/xray-client.json" ]; then
    CONFIG="$REPO_ROOT/out/client/$RG/xray-client.json"
else
    CONFIG="$REPO_ROOT/out/client/xray-client.json"
fi

if [ ! -f "$CONFIG" ]; then
    echo "verify_proxy.sh: $CONFIG not found — run 'just az-client' first." >&2
    echo "  (REALITY only; vpn_protocol=vmess_ws does not emit an xray client config.)" >&2
    exit 1
fi

command -v docker >/dev/null || { echo "verify_proxy.sh: docker not on PATH" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "verify_proxy.sh: docker daemon not reachable" >&2; exit 1; }

# Server address the client will dial, so we can compare it with the egress IP.
SERVER=$(sed -n 's/.*"address":[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)
SERVER_IP=$(dig +short "$SERVER" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)
[ -n "$SERVER_IP" ] || SERVER_IP="$SERVER"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Dialling $SERVER ($SERVER_IP) through a throwaway $XRAY_IMAGE client ..."

# --user 0:0 so the container can read the 0600 client config (it embeds the
# UUID and stays 0600 on the host). -confdir is the image's default CMD, hence
# mounting the file at that exact path.
docker run -d --rm --name "$CONTAINER" \
    --user 0:0 \
    -p "127.0.0.1:$SOCKS_PORT:10808" \
    -v "$CONFIG:/usr/local/etc/xray/config.json:ro" \
    "$XRAY_IMAGE" >/dev/null

# Xray binds its inbound in well under a second, but the published port needs a
# moment; poll instead of sleeping a fixed amount.
for _ in $(seq 1 20); do
    if nc -z 127.0.0.1 "$SOCKS_PORT" 2>/dev/null; then break; fi
    sleep 0.25
done

fail=0
proxy="socks5h://127.0.0.1:$SOCKS_PORT"

code=$(curl -sS --max-time 20 -x "$proxy" -o /dev/null -w '%{http_code}' \
    https://www.gstatic.com/generate_204 2>/dev/null || echo "000")
if [ "$code" = "204" ]; then
    printf "  ok   %-40s -> %s\n" "traffic flows (generate_204)" "$code"
else
    printf "  FAIL %-40s -> %s (expected 204)\n" "traffic flows (generate_204)" "$code"
    fail=1
fi

egress=$(curl -sS --max-time 20 -x "$proxy" https://api.ipify.org 2>/dev/null || true)
if [ -z "$egress" ]; then
    printf "  FAIL %-40s -> <no response>\n" "egress IP is the VPS"
    fail=1
elif [ "$egress" = "$SERVER_IP" ]; then
    printf "  ok   %-40s -> %s\n" "egress IP is the VPS" "$egress"
else
    # Not necessarily broken — a VPS can egress from a different address than
    # the one it's reached on — but it is worth a look.
    printf "  WARN %-40s -> %s (server resolves to %s)\n" "egress IP is the VPS" "$egress" "$SERVER_IP"
fi

if [ "$fail" -ne 0 ]; then
    echo
    echo "Client-side log:"
    docker logs "$CONTAINER" 2>&1 | tail -20
    echo
    echo "Server-side:"
    echo "  ansible vpn -a 'docker logs --tail 100 xray'"
    exit 1
fi

echo "Proxy works end to end."
