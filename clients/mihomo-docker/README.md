# Mihomo Docker client (VLESS / Reality)

Legacy [`../docker`](../docker) uses Dreamacro / Kuingsmile **Clash v1.18** — **no VLESS Reality**.  
This stack is the MetaCubeX **mihomo** equivalent for IDC / rootless Docker hosts.

## Ports (side-by-side with old Clash)

| Stack | Mixed | API |
|-------|-------|-----|
| Legacy Clash (`~/clash`) | **7892** | **9090** |
| This mihomo | **7890** | **9091** |

## Why Alpine + bind-mounted binary?

On GFW / air-gapped IDC hosts, `docker pull metacubex/mihomo` and Docker Hub often time out.  
Alpine is usually already cached; mount a static `mihomo-linux-amd64` instead.

```bash
VER=v1.19.15
curl -fL -o mihomo-linux-amd64.gz \
  "https://github.com/MetaCubeX/mihomo/releases/download/${VER}/mihomo-linux-amd64-${VER}.gz"
gunzip -f mihomo-linux-amd64.gz
chmod +x mihomo-linux-amd64

cp config.example.yaml config.yaml   # fill secrets
cp ../docker/Country.mmdb ./Country.mmdb   # or download geo DB

export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock   # rootless
docker compose up -d
```

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
