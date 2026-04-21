#!/bin/bash
# Smoke test the deployed VPN server.
#
# Usage: DOMAIN=your.domain.tld ./scripts/verify.sh
#        (or source an .env that sets DOMAIN)

set -euo pipefail

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
