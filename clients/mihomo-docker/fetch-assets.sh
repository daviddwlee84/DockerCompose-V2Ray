#!/bin/bash
# Fetch the runtime assets that docker-compose.binary.yaml bind-mounts:
# the mihomo release binary and the GeoIP database.
#
# Not needed for the default docker-compose.yaml — the official image already
# ships both. This is only for hosts that cannot pull from Docker Hub.
#
# Usage:
#   ./fetch-assets.sh                          # latest release, arch from uname -m
#   ./fetch-assets.sh --version v1.19.29       # pin a version
#   ./fetch-assets.sh --arch arm64             # cross-prep for another host
#   ./fetch-assets.sh --arch amd64-compatible  # old CPU (fixes "Illegal instruction")
#   ./fetch-assets.sh --with-geosite           # also fetch geosite.dat (GEOSITE rules)
#   ./fetch-assets.sh --force                  # re-download even if present
#
#   VERSION= and ARCH= env vars work too; flags win.
#
# Writes into this directory: mihomo, geoip.metadb, .assets-version
# (plus geosite.dat with --with-geosite). All are gitignored.

set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
SELF=$(basename "$0")

MIHOMO_REPO=MetaCubeX/mihomo
GEO_URL=https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest

# Used only when the GitHub API is unreachable or rate-limited (60 req/hr
# unauthenticated). Bump alongside the image tag in docker-compose.yaml.
FALLBACK_VERSION=v1.19.29

VERSION="${VERSION:-}"
ARCH="${ARCH:-}"
WITH_GEOSITE=0
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            shift
            [ $# -gt 0 ] || { echo "$SELF: --version requires an argument" >&2; exit 2; }
            VERSION="$1"
            ;;
        --version=*) VERSION="${1#--version=}" ;;
        --arch)
            shift
            [ $# -gt 0 ] || { echo "$SELF: --arch requires an argument" >&2; exit 2; }
            ARCH="$1"
            ;;
        --arch=*) ARCH="${1#--arch=}" ;;
        --with-geosite) WITH_GEOSITE=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "$SELF: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# curl or wget — minimal / air-gapped hosts tend to have one or the other.
if command -v curl >/dev/null 2>&1; then
    fetch()        { curl -fsSL --retry 3 -o "$1" "$2"; }
    fetch_stdout() { curl -fsSL --retry 3 "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch()        { wget -q -O "$1" "$2"; }
    fetch_stdout() { wget -q -O - "$1"; }
else
    echo "$SELF: need curl or wget" >&2
    exit 1
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# --- resolve version ---------------------------------------------------------

if [ -z "$VERSION" ]; then
    VERSION=$(fetch_stdout "https://api.github.com/repos/$MIHOMO_REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)
    if [ -z "$VERSION" ]; then
        VERSION=$FALLBACK_VERSION
        echo "$SELF: GitHub API unreachable or rate-limited; falling back to $VERSION" >&2
    fi
fi

# --- resolve arch ------------------------------------------------------------

if [ -z "$ARCH" ]; then
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)  ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        armv7l|armv7)  ARCH=armv7 ;;
        armv6l|armv6)  ARCH=armv6 ;;
        i386|i686)     ARCH=386 ;;
        riscv64)       ARCH=riscv64 ;;
        *) echo "$SELF: unrecognised machine '$machine' — pass --arch explicitly" >&2; exit 1 ;;
    esac
    # uname reports the machine running this script, which is not necessarily
    # the machine that will run the container (e.g. prepping files to scp).
    if [ "$(uname -s)" != "Linux" ]; then
        echo "$SELF: warning: host is $(uname -s), not Linux — guessed --arch $ARCH from '$machine'." >&2
        echo "$SELF: the container needs a linux build; pass --arch if the target differs." >&2
    fi
fi

echo "mihomo $VERSION  linux/$ARCH  ->  $DIR"

# --- binary ------------------------------------------------------------------

STAMP="$DIR/.assets-version"
want="$VERSION $ARCH"

if [ "$FORCE" -eq 0 ] && [ -f "$DIR/mihomo" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$want" ]; then
    echo "  mihomo $want already present — skipping (--force to re-download)"
else
    asset="mihomo-linux-${ARCH}-${VERSION}.gz"
    echo "  downloading $asset ..."
    if ! fetch "$DIR/.mihomo.gz.part" "https://github.com/$MIHOMO_REPO/releases/download/$VERSION/$asset"; then
        rm -f "$DIR/.mihomo.gz.part"
        echo "$SELF: download failed — check that '$asset' exists in the $VERSION release." >&2
        echo "$SELF: asset list: https://github.com/$MIHOMO_REPO/releases/tag/$VERSION" >&2
        exit 1
    fi
    # Upstream publishes no checksum for the release binaries, only for geo data.
    gzip -dc "$DIR/.mihomo.gz.part" > "$DIR/mihomo.part"
    rm -f "$DIR/.mihomo.gz.part"
    chmod +x "$DIR/mihomo.part"
    mv "$DIR/mihomo.part" "$DIR/mihomo"
    printf '%s\n' "$want" > "$STAMP"
fi

# --- geo data ----------------------------------------------------------------

# Same files the official image bakes in. geoip.metadb backs the GEOIP,CN rule
# in config.example.yaml; mihomo also accepts Country.mmdb / geoip.db there.
fetch_geo() {
    local name="$1" expected actual
    if [ "$FORCE" -eq 0 ] && [ -f "$DIR/$name" ]; then
        echo "  $name already present — skipping (--force to refresh)"
        return 0
    fi
    echo "  downloading $name ..."
    fetch "$DIR/$name.part" "$GEO_URL/$name"
    expected=$(fetch_stdout "$GEO_URL/$name.sha256sum" 2>/dev/null | awk 'NR==1 {print $1}' || true)
    actual=$(sha256_of "$DIR/$name.part")
    if [ -n "$expected" ] && [ -n "$actual" ]; then
        if [ "$expected" != "$actual" ]; then
            rm -f "$DIR/$name.part"
            echo "$SELF: checksum mismatch for $name (expected $expected, got $actual)" >&2
            exit 1
        fi
        echo "    sha256 ok"
    else
        echo "    (checksum unavailable — skipped)"
    fi
    mv "$DIR/$name.part" "$DIR/$name"
}

fetch_geo geoip.metadb
if [ "$WITH_GEOSITE" -eq 1 ]; then
    fetch_geo geosite.dat
fi

# --- next steps --------------------------------------------------------------

echo
echo "Done. Next:"
[ -f "$DIR/config.yaml" ] || echo "  cp config.example.yaml config.yaml   # fill UUID / Reality keys"
echo "  docker compose -f docker-compose.binary.yaml up -d"
if [ "$WITH_GEOSITE" -eq 1 ]; then
    echo
    echo "Uncomment the geosite.dat mount in docker-compose.binary.yaml to use it."
fi
