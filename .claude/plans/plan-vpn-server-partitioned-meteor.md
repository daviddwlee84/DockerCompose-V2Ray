# Plan: Centralized observability (Grafana LGTM) for a fleet of V2Ray servers

## Context

Today the repo runs a single-operator V2Ray VPN with **zero observability**: nginx and
v2ray write `access.log`/`error.log` to host bind mounts (`/opt/vpn/runtime/logs/{nginx,v2ray}`),
rotated by a `logrotate` cron; container stdout uses Docker's default `json-file` driver.
There is no metrics surface anywhere — the V2Ray config has **no `stats`/`api`/`policy`/`routing`**,
nginx has no `stub_status`, and there are no exporters, Prometheus, Grafana, or log shipping.

The goal is to scale this to **many VPN servers** with one central Grafana that:
1. collects logs **and** metrics from every server,
2. enforces **retention** so storage doesn't blow up,
3. serves **pre-built, plug-and-play dashboards** with a top-of-dashboard **`$server` dropdown**
   that auto-lists whatever servers are currently reporting (new server plugs in → appears in the
   dropdown, no dashboard edits),
4. answers the open question *"is there anything worth tuning server-side?"* — **yes**: enabling the
   V2Ray StatsService gives per-user / per-inbound uplink-downlink byte counters, which is the single
   most valuable server-side knob (most other V2Ray tuning genuinely is client-side).

### Assumed decisions (I chose the recommended option on each; flip any if wrong)
- **Central stack packaging:** all-in-one `grafana/otel-lgtm` (the image you referenced). Retention is
  configurable via `PROMETHEUS_EXTRA_ARGS` / `LOKI_EXTRA_ARGS` + a mounted `/data` volume, and it
  bundles Grafana + Prometheus + Loki + Tempo + Pyroscope + OTel Collector. Grafana scopes it to
  "dev/demo," but it's the right pragmatic choice at single-operator / handful-of-servers scale.
- **Server-side depth:** **Full** — V2Ray traffic stats + host metrics + nginx + log shipping.
- **Ingest / exposure:** **reuse this repo's nginx + certbot Let's Encrypt pattern** on the central
  host. Agents push **outbound** over HTTPS; no new inbound ports on any VPN server.
- **Profiling / traces:** **deferred**. A VMess proxy emits no distributed traces and isn't worth
  CPU-profiling; metrics + logs carry ~all the value. Pyroscope/Tempo stay present (bundled) but
  unwired. Dashboards focus on traffic / bandwidth / host health / logs.

---

## Architecture

Two additions, each following an existing pattern in the repo.

```
 VPN server (existing /opt/vpn compose project)          Central host (NEW /opt/obs project)
 ┌───────────────────────────────────────────┐          ┌──────────────────────────────────────┐
 │ v2ray ─(StatsService gRPC :api_port)─┐     │          │ nginx + certbot  (reused pattern)     │
 │ nginx ─(stub_status, localhost)──┐   │     │  HTTPS   │   /       → grafana:3000 (Grafana auth)│
 │ node_exporter, cadvisor ─────┐   │   │     │  OTLP    │   /otlp   → otel-lgtm:4318 (basic-auth)│
 │ log files (bind mount) ──┐   │   │   │     │  push    │                                        │
 │                          ▼   ▼   ▼   ▼     │ ───────► │ otel-lgtm: Prometheus+Loki+Grafana     │
 │              Grafana Alloy (single agent)  │ outbound │   retention via *_EXTRA_ARGS           │
 │              scrape + tail → OTLP export ──┼──────────┤   /data on a persistent host volume    │
 └───────────────────────────────────────────┘   443    └──────────────────────────────────────┘
     firewall: 22/80/443 in only; agent egresses on 443       new inventory group [observability]
```

**Why Grafana Alloy as the single per-server agent:** it does Prometheus scraping, log-file tailing,
relabeling (to stamp the per-server label), and OTLP export in one process — a cleaner fit for the
LGTM backend than stitching promtail + a prometheus agent + the OTel collector. Everything ships as
**OTLP/HTTP to one endpoint** (`/otlp`), so the central host needs exactly one authenticated ingest
route behind the existing nginx+TLS.

**Why outbound-only / OTLP:** VPN servers stay firewalled to 22/80/443 inbound (per
`firewall_allowed_tcp` in `group_vars/all.yml`). All exporters stay on the internal compose bridge
(`expose:`, never `ports:`), and Alloy egresses on 443 — so **no firewall changes on VPN servers**
and no metrics surface exposed to the internet.

**Plug-and-play `$server` dropdown:** Alloy stamps every metric/log with a `server` label
(= `monitoring_server_label`, defaulting to `inventory_hostname`). Provisioned dashboards define
`$server = label_values(server)`. A newly-deployed server shows up in the dropdown automatically —
no dashboard edits.

---

## Part A — Per-server agent + exporters (extends the existing `vpn` role)

All changes keep the tracked `server/…` truth-source and the rendered `ansible/roles/vpn/templates/…`
`.j2` in lockstep (repo rule). Everything is gated behind a `monitoring_enabled` flag so it can be
switched off per host/group.

1. **V2Ray config — enable StatsService** (`ansible/roles/vpn/templates/v2ray/config.json.j2`
   + `server/templates/v2ray/config.json.tmpl`). Add, alongside the existing vmess inbound/freedom
   outbound:
   - `"stats": {}`
   - `"api": { "tag": "api", "services": ["StatsService"] }`
   - `"policy": { "levels": {"1": {"statsUserUplink": true, "statsUserDownlink": true}},
     "system": {"statsInboundUplink": true, "statsInboundDownlink": true,
     "statsOutboundUplink": true, "statsOutboundDownlink": true} }`
   - a `"tag": "proxy"` on the existing vmess inbound, and an `"email"` on the client (so a
     `user>>>…>>>traffic` stat key exists for per-user breakdown)
   - a second inbound: `dokodemo-door` on `127.0.0.1`-of-the-compose-network, port
     `{{ v2ray_api_port }}`, `"tag": "api"` (exposed internally only — reached by the exporter over
     the compose network, never host-published)
   - `"routing": { "rules": [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}] }`

2. **nginx `stub_status`** (`ansible/roles/vpn/templates/nginx/v2ray.conf.j2` + `.tmpl`): add an
   internal-only `server { listen 127.0.0.1:<port>; location /nginx_status { stub_status; } }` (or a
   `location` restricted to the compose network) for the nginx exporter to scrape. Does **not** touch
   the public 80/443 server blocks.

3. **New compose services** appended to `ansible/roles/vpn/templates/compose.yml.j2` +
   `server/compose.yml`, each `expose:`-only (no `ports:`), all `{% if monitoring_enabled %}`-guarded:
   - `v2ray-exporter` — `wi1dcard/v2ray-exporter`, points at `v2ray:{{ v2ray_api_port }}` → per-user/
     per-inbound uplink/downlink byte metrics.
   - `node-exporter` — `prom/node-exporter`, host `/proc`,`/sys`,`/` mounted read-only.
   - `cadvisor` — `gcr.io/cadvisor/cadvisor`, per-container CPU/mem/net.
   - `nginx-exporter` — `nginx/nginx-prometheus-exporter`, scrapes the stub_status listener.
   - `alloy` — `grafana/alloy`, mounts `runtime/logs/{nginx,v2ray}` read-only + its rendered config;
     scrapes the four exporters, tails the log files, and OTLP-pushes to `{{ obs_endpoint }}` with
     basic-auth.

4. **Alloy config template** — new `ansible/roles/vpn/templates/alloy/config.alloy.j2`
   + `server/templates/alloy/config.alloy.tmpl`. `prometheus.scrape` the exporters,
   `loki.source.file` the log files, relabel to add `server="{{ monitoring_server_label }}"`, export
   via `otelcol.exporter.otlphttp` to `{{ obs_endpoint }}`. Render task + `runtime/alloy` dir added to
   `ansible/roles/vpn/tasks/main.yml` (mirror the existing `runtime/v2ray` dir-create + render +
   `notify: recreate stack` steps); add `runtime/alloy` to the dir-tree task.

5. **New variables**:
   - `ansible/group_vars/all.yml`: `monitoring_enabled: false` (opt-in), `v2ray_api_port: 10085`,
     `monitoring_server_label: "{{ inventory_hostname }}"`, `obs_endpoint: ""` (central OTLP URL).
   - Secrets via the established `vault_* → plain-name` indirection
     (`ansible/group_vars/vpn/vars.yml` + `vault.yml`): `obs_ingest_user`, `obs_ingest_password`.
   - No `firewall_allowed_tcp` change (egress-only).

## Part B — Central observability host (NEW, mirrors vpn + letsencrypt patterns)

1. **Inventory**: add `[observability]` group + `[observability:vars]` to
   `ansible/inventory/prod.ini.example` (and the real gitignored `prod.ini`). One host to start.

2. **group_vars**: `ansible/group_vars/observability/vars.yml` +
   `vault.yml.example` — `obs_domain`, `obs_letsencrypt_email`, `grafana_admin_password`, and the
   `obs_ingest_user`/`obs_ingest_password` that must match Part A. Retention knobs:
   `loki_retention: 30d` (logs are the space hog), `prometheus_retention: 90d` (metrics are cheap).

3. **New role `ansible/roles/observability/`** — self-contained (does **not** couple to the `vpn`
   role's templates), rendering a compose project into a separate `deploy_path` (`/opt/obs`):
   - `otel-lgtm` service — pinned image tag, `PROMETHEUS_EXTRA_ARGS=--storage.tsdb.retention.time={{ prometheus_retention }}`,
     `LOKI_EXTRA_ARGS=--limits.retention-period={{ loki_retention }}`, `GF_SECURITY_ADMIN_PASSWORD`,
     and a **named/host volume mounted at `/data`** for persistence across redeploys.
   - `nginx` + `certbot` — copied from the vpn role's proven templates, retargeted: TLS-terminate
     `obs_domain`, reverse-proxy `/` → `otel-lgtm:3000` and `/otlp` → `otel-lgtm:4318` with
     `auth_basic` for ingest. Reuse the **two-phase Let's Encrypt bootstrap** logic from
     `ansible/roles/letsencrypt/tasks/main.yml` (acme-only conf → certbot --webroot → full conf →
     compose up), inlined into this role so it stays decoupled.
   - **Grafana provisioning**: mount datasource + dashboard-provider YAML and dashboard JSON into the
     otel-lgtm Grafana provisioning dir. Tracked assets live under `server/observability/` (compose
     tmpl, nginx tmpl, grafana provisioning, `dashboards/*.json`).

4. **Dashboards** (`server/observability/dashboards/*.json`, provisioned): each defines
   `$server = label_values(server)` at the top. Panels — bandwidth in/out per server (v2ray inbound
   stats + node_exporter net), per-user traffic (v2ray user stats), active connections
   (nginx stub_status), host CPU/mem/disk, container health (cadvisor), and a Loki logs panel filtered
   by `$server`. Start with one "Fleet overview" + one "Per-server drilldown" dashboard.

5. **Playbook + Justfile + docs**: `ansible/playbooks/observability.yml` (targets `[observability]`,
   runs `common` + `docker` + `observability`); Justfile recipes `deploy-obs`, `logs-obs`,
   `ps-obs`; `docs/OBSERVABILITY.md` covering the architecture, retention sizing, and adding a server.

## Retention / storage sizing (the "will blow up" concern)

- **Logs (Loki)** are the space hog on a VPN. Cap with `--limits.retention-period` (e.g. 30d) + the
  compactor; consider raising V2Ray `loglevel` from `warning` only if you want access-log-derived
  metrics (more volume). Keep access logs at `warning`/off unless needed.
- **Metrics (Prometheus)** for a handful of hosts at 15–60s scrape are tiny; `--storage.tsdb.retention.time=90d`
  is comfortable on a modest disk. Optionally add `--storage.tsdb.retention.size`.
- **Persistence**: mount `/data` to a host volume so retention survives `docker compose` recreation.
- Document expected disk (rule of thumb: metrics ≪ 1 GB/host/90d; logs dominate and scale with traffic).

---

## Critical files

**Modify (per-server, `vpn` role — keep `.tmpl` + `.j2` in lockstep):**
- `ansible/roles/vpn/templates/compose.yml.j2` + `server/compose.yml` — append 5 monitoring services (guarded).
- `ansible/roles/vpn/templates/v2ray/config.json.j2` + `server/templates/v2ray/config.json.tmpl` — stats/api/policy/routing + api inbound + client email.
- `ansible/roles/vpn/templates/nginx/v2ray.conf.j2` + `server/templates/nginx/v2ray.conf.tmpl` — internal `stub_status`.
- `ansible/roles/vpn/tasks/main.yml` — create `runtime/alloy`, render Alloy config, notify recreate.
- `ansible/group_vars/all.yml` — monitoring vars.
- `ansible/group_vars/vpn/vars.yml` + `vault.yml`(.example) — ingest creds indirection.

**Create (per-server):** `ansible/roles/vpn/templates/alloy/config.alloy.j2` + `server/templates/alloy/config.alloy.tmpl`.

**Create (central host):**
- `ansible/roles/observability/` (tasks/templates/defaults/handlers).
- `ansible/group_vars/observability/{vars.yml,vault.yml.example}`.
- `ansible/playbooks/observability.yml`.
- `server/observability/` (compose tmpl, nginx tmpl, grafana provisioning, `dashboards/*.json`).
- `docs/OBSERVABILITY.md`; `[observability]` group in `ansible/inventory/prod.ini.example`.
- `Justfile` recipes: `deploy-obs`, `logs-obs`, `ps-obs`.

**Reuse (don't reinvent):** the two-phase cert bootstrap in `ansible/roles/letsencrypt/tasks/main.yml`,
the nginx TLS/WS templates `ansible/roles/vpn/templates/nginx/{v2ray,acme-only}.conf.j2`, the
`community.docker.docker_compose_v2` + handler pattern in `ansible/roles/vpn/handlers/main.yml`, and
the `vault_* → plain-name` secret indirection.

---

## Verification

**Template rendering (local, no VPS needed):** `just test-up && just test-ping` — the Ubuntu test
container validates that the new `.j2` templates render (Jinja errors, missing vars). It can't run
dockerd, so it won't start services (documented harness limitation).

**Central host (real VPS):**
- `just deploy-obs`; `docker compose -f /opt/obs/compose.yml ps` → otel-lgtm + nginx + certbot healthy.
- `https://obs.<domain>` → Grafana login (admin pw from vault); TLS chain valid.
- Confirm retention flags are live: `docker compose exec otel-lgtm ps` shows Prometheus with
  `--storage.tsdb.retention.time` and Loki with the retention limit.

**VPN server (real VPS, `monitoring_enabled: true` + `obs_endpoint` set):**
- `just deploy-fast`; `docker compose -f /opt/vpn/compose.yml ps` → alloy + 4 exporters up.
- `docker compose exec v2ray v2ray api stats` (or the exporter's `/metrics` over the compose net)
  shows `v2ray_…_uplink`/`downlink` counters.
- `docker compose logs alloy` shows successful OTLP pushes to `obs_endpoint` (no auth/connection errors).

**End-to-end:** after one VPN server reports, open Grafana → the `$server` dropdown lists that host;
bandwidth/host panels populate; the Loki logs panel shows nginx/v2ray lines filtered by `$server`.
Deploy a second server with monitoring on → it appears in the dropdown with no dashboard edits.
