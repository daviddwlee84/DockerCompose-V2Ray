# Mihomo Docker client (VLESS / Reality)

Legacy [`../docker`](../docker) uses Dreamacro / Kuingsmile **Clash v1.18** — **no VLESS Reality**.  
This stack is the MetaCubeX **mihomo** equivalent for IDC / rootless Docker hosts.

## Two compose files

| File | Image | Use when |
|------|-------|----------|
| **`docker-compose.yaml`** (default) | `metacubex/mihomo:v1.19.29` | Normal hosts. Multi-arch, geo DBs baked in. |
| `docker-compose.binary.yaml` | `alpine:latest` + bind-mounted binary | `docker pull` can't reach Docker Hub (GFW / air-gapped IDC). Needs `./fetch-assets.sh` first. |

Both declare `container_name: mihomo` on the same host ports and share one compose
project (the directory name), so switching files **replaces** the container rather
than running two.

## Ports (side-by-side with old Clash)

| Stack | Mixed | API |
|-------|-------|-----|
| Legacy Clash (`~/clash`) | **7892** | **9090** |
| This mihomo | **7890** | **9091** |

## Default: official image

```bash
cp config.example.yaml config.yaml   # fill secrets

export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock   # rootless
docker compose up -d
```

No `Country.mmdb` to fetch: the upstream image ships `geoip.metadb`, `geosite.dat`
and `geoip.dat` in `/root/.config/mihomo/`, so the `GEOIP,CN` rule works as-is.
It also carries `ca-certificates`, `tzdata` and `iptables`.

Caveat: those geo files are baked in at **image build time**, so pinning the tag
pins the geo data too. See [`docs/clash/GeoDB.md`](../../docs/clash/GeoDB.md) for
what they are, who maintains them, and how to keep them fresh.

Tag is pinned deliberately. `:latest` follows each upstream release; `:Alpha`
tracks the Alpha branch. Upstream publishes to **Docker Hub only** — there is no
`ghcr.io/metacubex/mihomo`.

## Fallback: alpine + bind-mounted binary

On GFW / air-gapped IDC hosts, `docker pull metacubex/mihomo` and Docker Hub often
time out. Alpine is usually already cached; mount a static binary instead.

```bash
./fetch-assets.sh                    # mihomo binary + geoip.metadb
cp config.example.yaml config.yaml   # fill secrets

export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock   # rootless
docker compose -f docker-compose.binary.yaml up -d
```

`fetch-assets.sh` resolves the latest release from the GitHub API (falling back to
a pinned version when rate-limited), maps `uname -m` to the right release asset,
and verifies the geo DB against its published `.sha256sum`. Useful flags:

| Flag | Why |
|------|-----|
| `--arch arm64` | Prepping files for a different host than the one running the script. |
| `--arch amd64-compatible` | Old CPU — fixes `Illegal instruction` on the default build. |
| `--version v1.19.29` | Pin instead of tracking latest. |
| `--with-geosite` | Fetch `geosite.dat` too (only needed once you add GEOSITE rules). |
| `--force` | Re-download; geo data is refreshed daily upstream. |

The geo DB is required here — mihomo accepts `geoip.metadb`, `Country.mmdb` or
`geoip.db` in its config dir, and without one the `GEOIP,CN` rule fails. Note
that bare alpine has no `ca-certificates` or `tzdata`; fine for the current
config, but DoH nameservers would need them.

Fetched assets (`mihomo`, `geoip.metadb`, `.assets-version`) and your real
`config.yaml` are gitignored.

## Verify

```bash
curl -s http://127.0.0.1:9091/version
curl -s -x http://127.0.0.1:7890 https://api.ipify.org; echo

# optional: force selector
curl -s -X PUT http://127.0.0.1:9091/proxies/PROXY \
  -H 'Content-Type: application/json' \
  -d '{"name":"Az Sg"}'
```

## Claude Code / Copilot on the same host

Legacy Clash mixed port is often **7892**; this mihomo stack uses **7890**.
Point Claude Code at mihomo, not the old container:

```bash
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890
# optional: ALL_PROXY=socks5://127.0.0.1:7890
```

In `~/.claude/settings.local.json` set the same `env` block (Claude Code reads
settings env **over** inherited shell vars). Restart existing `claude` sessions
after changing ports.

Verify routing (401/200 = reachable; 401 is expected without API key):

```bash
curl -sS -o /dev/null -w "%{http_code}\n" -x http://127.0.0.1:7890 https://api.anthropic.com/v1/models
curl -sS -o /dev/null -w "%{http_code}\n" -x http://127.0.0.1:7890 https://api.github.com
```

## Related stacks

| Host | Client |
|------|--------|
| macOS | Clash Verge Rev (`verge-mihomo`, mixed **7897**) |
| Ubuntu desktop | mihomo user systemd (`~/.config/mihomo`, **7890**) |
| IDC / friend host | **this Docker compose** |

Do **not** commit real UUID / Reality keys into this repo.
