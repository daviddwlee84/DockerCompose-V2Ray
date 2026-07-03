# Observability — centralized Grafana LGTM for a fleet of VPN servers

Optional add-on. One central host runs Grafana + Prometheus + Loki (+ Tempo +
Pyroscope, unused for now) via the [`grafana/otel-lgtm`][lgtm] all-in-one image.
Every VPN server runs a small [Grafana Alloy][alloy] agent + exporters that ship
**metrics and logs outbound** to the central host. Pre-built dashboards have a
`$server` dropdown that auto-lists whatever servers are currently reporting — a
new server plugs in and appears with no dashboard edits.

It is **off by default** (`monitoring_enabled: false`). Nothing changes on the
VPN servers until you turn it on.

```
 VPN server (existing /opt/vpn stack)                Central host (/opt/obs)
 ┌──────────────────────────────────────┐            ┌───────────────────────────────┐
 │ v2ray ─StatsService gRPC :10085─┐     │            │ obs-nginx + certbot (TLS)      │
 │ nginx ─stub_status :8081──┐     │     │  HTTPS     │  /prom → Prometheus  [auth]    │
 │ node-exporter, cadvisor ┐ │     │     │  push      │  /loki → Loki        [auth]    │
 │ log files (bind mount) ┐│ │     │     │ ─────────► │  /     → Grafana (login)       │
 │            Grafana Alloy (agent) ─────┼────────────┤  otel-lgtm: Prom+Loki+Grafana  │
 │            scrape + tail → remote_write│  outbound  │  retention + obs-data volume   │
 └──────────────────────────────────────┘    443     └───────────────────────────────┘
   firewall unchanged: 22/80/443 in only          inventory group [observability]
```

## What gets collected

Per VPN server, all scraped locally over the compose network (nothing is exposed
to the internet — the exporters use `expose:`, never `ports:`):

| Source | Exporter | Signal |
|---|---|---|
| V2Ray StatsService | `wi1dcard/v2ray-exporter` | per-inbound + per-user uplink/downlink **bytes** (the bandwidth view) |
| Host | `prom/node-exporter` | CPU, memory, disk, network throughput |
| Containers | `cadvisor` | per-container CPU/mem/net |
| nginx | `nginx/nginx-prometheus-exporter` | active connections, request rate |
| nginx + v2ray logs | Alloy `loki.source.file` | `access.log` / `error.log` lines → Loki |

Alloy stamps a `server="<inventory host>"` label (`monitoring_server_label`) on
everything, then pushes: metrics via **Prometheus remote-write** to
`<obs_base_url>/prom/api/v1/write` and logs via **Loki push** to
`<obs_base_url>/loki/api/v1/push`, both with basic auth.

## Is there anything worth tuning on the *server*? (Yes: V2Ray stats)

Most V2Ray tuning genuinely is client-side. The one high-value server-side knob
is the **StatsService**, which this feature turns on. When `monitoring_enabled`,
`roles/vpn/templates/v2ray/config.json.j2` gains:

- `"stats": {}` and `"api": { "tag": "api", "services": ["StatsService"] }`
- a `"policy"` block enabling `statsUser*` + `statsInbound*` / `statsOutbound*`
- a `dokodemo-door` **api inbound** on `127.0.0.1`-of-the-compose-net, port
  `v2ray_api_port` (10085), tagged `api`, plus a routing rule pinning it to the
  api outbound
- `"tag": "proxy"` on the vmess inbound and `"email": "primary"` on the client so
  the counters are keyed by inbound and by user

That's what produces `v2ray_traffic_{up,down}link_bytes_total{dimension,target}`
— i.e. "who used how much bandwidth." Without it there is no traffic accounting
at all. `alterId: 64` / VMess is unchanged (protocol migration is out of scope).

## Enable it

### 1. Central host first

Add an `[observability]` host to `ansible/inventory/prod.ini` (see
`prod.ini.example`) — one host is enough. Create its vault:

```bash
cp ansible/group_vars/observability/vault.yml.example ansible/group_vars/observability/vault.yml
just vault-edit            # or: ansible-vault edit ansible/group_vars/observability/vault.yml
# set: vault_obs_domain, vault_obs_letsencrypt_email, vault_grafana_admin_password,
#      vault_obs_ingest_user, vault_obs_ingest_password
just vault-encrypt         # if you created it unencrypted
just deploy-obs
```

Point `obs.<domain>`'s DNS A record at the host first (certbot needs HTTP-01 on
port 80, same two-phase bootstrap as the VPN stack). Then `https://obs.<domain>`
→ Grafana login (admin / `vault_grafana_admin_password`).

### 2. Turn on monitoring for the VPN servers

Set these for the `vpn` group (e.g. in `group_vars/vpn/vars.yml` or per host) and
in each VPN host's vault:

```yaml
# group_vars/all.yml (or vpn) — non-secret
monitoring_enabled: true
obs_base_url: "https://obs.example.com"     # no trailing slash

# each VPN host's vault (must match the obs host's values)
vault_obs_ingest_user: "vpn-agent"
vault_obs_ingest_password: "…shared secret…"
```

Then `just deploy` (or `just deploy-fast` for the app-only path). The `recreate
stack` handler brings up the agent + exporters; the V2Ray config is re-rendered
with the StatsService and v2ray restarts once.

## The `$server` dropdown (plug-and-play)

The dashboard variable `$server` is `label_values(node_uname_info, server)`.
Because every agent stamps its own `server` label, a newly-deployed server starts
reporting and shows up in the dropdown automatically. To add a **dashboard**,
drop a JSON file into `server/observability/grafana/dashboards/` and
`just deploy-obs` — the provider (`dashboards.yaml`) auto-loads it.

## Retention & sizing (so it doesn't fill up)

Set on the obs host (`roles/observability/defaults/main.yml`, overridable):

- `prometheus_retention: "90d"` → `--storage.tsdb.retention.time`. Metrics for a
  handful of hosts are tiny (≪ 1 GB / host / 90d).
- `loki_retention: "30d"` → `--limits.retention-period`. **Logs are the space
  hog** and scale with traffic — keep this shorter.

Data persists in the Docker named volume `obs-data` (mounted at `/data`). Check
usage with `docker system df -v`. If logs are *not* actually being deleted at the
retention horizon, the otel-lgtm Loki may need its compactor's `retention_enabled`
turned on — mount a custom Loki config into the container (the image supports
config overrides) as a follow-up.

## Security model

- **VPN servers stay firewalled** to 22/80/443 inbound. The agent only egresses
  (443) — no new inbound ports, no metrics surface on the internet.
- The obs host's ingest (`/prom`, `/loki`) is **TLS + basic-auth** (nginx
  `auth_basic`, `{PLAIN}` htpasswd; the same secret is already in each agent's
  config, so it's not hashed at rest — swap for `openssl passwd -apr1` if you
  want). Grafana has its own login.
- The obs host aggregates every server's data — treat it as sensitive. Consider
  restricting `443` to known IPs, or fronting Grafana with SSO, if it's public.

## Profiling & traces (deferred, on purpose)

otel-lgtm bundles Tempo (traces) and Pyroscope (profiles), but they are **not
wired up**. A VMess proxy emits no distributed traces and isn't worth CPU-
profiling — metrics + logs carry ~all the value here. To add continuous
profiling later you'd run a Grafana Alloy/OBI eBPF agent (privileged) on each
VPN server pushing to Pyroscope; that's extra privilege on the proxy box for
marginal insight, hence left out.

## Verify / troubleshoot

```bash
just ps-obs                      # otel-lgtm + obs-nginx + obs-certbot healthy?
just logs-obs                    # otel-lgtm (Grafana/Prometheus/Loki) logs
just ps                          # on a VPN host: alloy + 4 exporters up?
```

- **Agent can't push** → `docker logs alloy` on the VPN host. 401 = ingest creds
  mismatch (`obs_ingest_*` must match on both sides). Connection refused =
  `obs_base_url` wrong or DNS/cert not ready.
- **Grafana has no metrics** but agent looks fine → from the obs host confirm the
  backends are reachable cross-container:
  `docker exec obs-nginx wget -qO- http://otel-lgtm:9090/-/ready` and
  `.../otel-lgtm:3100/ready`. If refused, a backend bound to localhost inside the
  image — add `--web.listen-address=0.0.0.0:9090` to `PROMETHEUS_EXTRA_ARGS`.
- **V2Ray counters empty** → on the VPN host,
  `docker exec v2ray v2ray api --server=127.0.0.1:10085 StatsService.QueryStats ''`
  (or check `http://v2ray-exporter:9550/scrape` from inside the compose net).
- **`$server` dropdown empty** → node-exporter isn't reporting yet; give it a
  scrape interval (30s) and confirm remote-write is landing in Prometheus.

[lgtm]: https://github.com/grafana/docker-otel-lgtm
[alloy]: https://grafana.com/docs/alloy/latest/
