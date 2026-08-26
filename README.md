# DockerCompose-V2Ray

A personal VPN server, deployed via Ansible. The default protocol is **VLESS + XTLS-Vision + REALITY** on Xray-core: Xray owns port 443 and borrows its TLS handshake from a real site, so an unauthenticated prober is transparently forwarded to that site and there is no certificate of ours to fingerprint. nginx keeps port 80 for a landing page.

The previous **VMess over WebSocket + TLS** stack (nginx terminating Let's Encrypt TLS) is still available as `vpn_protocol: vmess_ws`, and `both` runs them side by side during a migration. See [`docs/ProtocolEvaluation.md`](docs/ProtocolEvaluation.md) for why the default changed and [`docs/REALITY-MIGRATION.md`](docs/REALITY-MIGRATION.md) for how to operate it.

## Deploy

On a fresh Ubuntu VPS with SSH open and ports 22/80/443 reachable at the cloud firewall, pointed at by your domain.

**All tooling runs on your laptop.** Ansible drives the VPS over SSH — the
server itself needs nothing pre-installed beyond `sshd` and a user with
passwordless sudo; Docker and everything else is installed by the playbook
on first run. (See [`ansible/README.md`](ansible/README.md) for the long
form, including how to point Ansible at the host.)

```bash
# On laptop, one-time setup:
brew install just                                             # macOS / Linuxbrew
# Debian/Ubuntu: sudo apt install -y just  (24.04+) — or grab a prebuilt binary
#                from https://just.systems/
just setup                                                    # installs ansible + jq + uv + ansible-galaxy collections
                                                              # auto-detects brew / apt; falls back to manual hints.
cp ansible/inventory/prod.ini.example ansible/inventory/prod.ini
$EDITOR ansible/inventory/prod.ini                            # fill in your host
cp ansible/group_vars/vpn/vault.yml.example ansible/group_vars/vpn/vault.yml
just reality-keys --format vault-yaml                         # generates the REALITY keypair + short ID
$EDITOR ansible/group_vars/vpn/vault.yml                      # fill domain, email, uuid, REALITY keys
just vault-encrypt
echo 'your-vault-password' > ~/.vault-pass && chmod 600 ~/.vault-pass
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault-pass

# Deploy:
just deploy                                                   # ~5 min first run
DOMAIN=your.domain.tld just verify                            # front-door smoke test
just az-client && just verify-proxy                           # end-to-end: does traffic actually flow
```

What `just deploy` does: installs rootful Docker, hardens the OS (ufw, fail2ban, unattended-upgrades, timezone), renders server configs from Jinja2 templates + vault secrets, bootstraps Let's Encrypt via HTTP-01 (only in the `vmess_ws` / `both` modes — REALITY needs no certificate of ours), and brings up the Docker Compose stack.

Re-deploy after config edits: `just deploy-fast` (skips OS/Docker steps, just re-renders configs and reloads services). Rotate the UUID: `just rotate-uuid`.

See [`ansible/README.md`](ansible/README.md) for details (role structure, vault layout, rotating secrets).

> Prefer the old shell-script flow? It's frozen at the [`pre-iac-refactor`](../../tree/pre-iac-refactor) tag. See [`docs/LEGACY.md`](docs/LEGACY.md).

## Repo layout

| Path | Purpose |
|---|---|
| `server/` | Everything that ends up on the VPS: `compose.yml`, `templates/` (source-of-truth configs with placeholders), `static/` (landing page), `runtime/` (generated at deploy time, gitignored). |
| `ansible/` | Playbooks, roles (`common`, `docker`, `vpn`, `letsencrypt`), inventory, vault. |
| `scripts/` | `install_docker.sh` (rootful bootstrap), `reality_keys.py` (x25519 keypair + short ID), `client_config.py` (client configs), `verify.sh` (front-door smoke test), `verify_proxy.sh` (end-to-end tunnel test). |
| `Justfile` | Laptop-side wrapper: `deploy`, `deploy-fast`, `reality-keys`, `rotate-uuid`, `verify`, `verify-proxy`, `logs-*`, `vault-edit`. |
| `clients/clash-verge/` | Desktop Clash Verge Rev runbook: official package install, generated-node import, traffic verification, two-core conflicts, and Linux duplicate-launcher diagnosis. |
| `clients/cli/` | Headless Linux client setup; the archived Clash-for-Windows / `clash-core` v1.18 flow is kept below a Legacy heading (it cannot do REALITY). |
| `clients/mihomo-docker/` | Dockerized **mihomo** client — the maintained one. `config.example.yaml` carries a VLESS+REALITY proxy plus the CN-side DNS setup. |
| `clients/docker/` | Dockerized Clash v1.18 proxy + YACD dashboard (git submodule). **No REALITY support** — use `clients/mihomo-docker/` instead. |
| `docs/` | `DeploymentEvaluation.md` + `BareMetalEvaluation.md` (why Ansible + Docker Compose, not Terraform + systemd), `ProtocolEvaluation.md` (why the default moved off VMess: an audit of what this repo actually shipped, plus VLESS/Reality/Hysteria2/etc. compared with GFW detection risk), `REALITY-MIGRATION.md` (the three `vpn_protocol` modes, key material, picking a `dest`, the pitfalls, rollback), `IP-ROTATION.md` (rotate a GFW-banned Azure IP while keeping the FQDN), `MULTI-HOST.md` (run multiple region VMs at once), `LOG-ROTATION.md` (logrotate config + manual patch recipe for a running VPS), `OBSERVABILITY.md` (optional central Grafana LGTM for a fleet — outbound metrics + logs, a `$server` plug-and-play dashboard, and the Xray StatsService as the one server-side tuning knob), `clash/` (client-side research notes: a recommended best-practice combo, mihomo vs current core, observability via Grafana/LGTM, the 9090 RESTful API, the client landscape incl. mobile, systematic config management, and how to self-host node/rule providers for Clash + Shadowrocket), `LEGACY.md` (pre-refactor flow), `old/` (archived notes: `FlowCharts.md` Clash routing, `XrayUI.md` alt admin panels). |
| `legacy/` | Archived pre-refactor files. Nothing here is used by the current flow. See [`legacy/README.md`](legacy/README.md). |

## One-shot Azure validation (throwaway VM)

If you just want to sanity-check the whole pipeline on a fresh Japan East VM
and tear it down afterwards, the helpers under [`scripts/`](scripts/) wrap the
`az` CLI around the existing Ansible deploy:

```bash
# Prereqs on the laptop: az cli (logged in), jq, uv, ansible, just.
# az_up.sh mints a fresh per-RG ed25519 keypair under .secrets/azure/<rg>/
# on every run; pass AZ_SSH_PUBKEY=... to reuse one you already trust.

just az-up            # preview cost, create RG + B2ats_v2 VM + NSG (22/80/443) + DNS
just az-configure     # render inventory/prod.ini + per-host host_vars/<rg>/vault.yml
just deploy           # existing ansible flow (common + docker + vpn + letsencrypt)
just verify           # with exactly one tracked VM; else RG=<rg> just verify
just az-client        # emit URLs, test config, fragments, and a ready-to-import clash-verge.yaml
just verify-proxy     # dial the node with a real xray client and confirm traffic flows
just az-rotate-ip     # rotate the public IP, keep the FQDN (use when GFW-banned; see docs/IP-ROTATION.md)
just az-down -y       # delete the RG (-y skips the type-the-name confirm)

# Or the whole loop in one shot, with a pause for manual testing before teardown:
AZ_YES=1 just az-cycle
```

Multiple VMs in different regions are supported — state is stored per-RG
under `.secrets/azure/vms/<rg>.json`, and each VM gets its own encrypted
`ansible/host_vars/<rg>/vault.yml`. `just deploy` targets every tracked host
at once; per-host commands (`just verify`, `just az-client`, `just az-down`,
`just az-rotate-ip`) take an explicit `<rg>` when more than one VM is
tracked. See [`docs/MULTI-HOST.md`](docs/MULTI-HOST.md) for the full flow.

`scripts/az_up.sh` queries the Azure Retail Prices API and shows an
hourly / daily / monthly estimate for the target (region, VM size) before
prompting; set `AZ_YES=1` to skip the confirm prompt. It also configures a
DevTest-Labs daily auto-shutdown at `AZ_SHUTDOWN_TIME` (default `1800` UTC ≈
02:00 Asia/Shanghai) as a safety net for forgotten VMs — set
`AZ_SHUTDOWN_TIME=off` to disable.

Other overrides (all env vars read by `scripts/az_up.sh`): `AZ_LOCATION`,
`AZ_VM_SIZE`, `AZ_VM_NAME`, `AZ_DNS_PREFIX`, `AZ_SSH_PUBKEY`, `AZ_RG`,
`AZ_IMAGE`, `AZ_ADMIN_USER`. Let's Encrypt email falls back
to `git config user.email` — set `LE_EMAIL=you@example.org` to override. A
throwaway vault password is written to `.secrets/.vault-pass` on first run
(gitignored). `out/client/` is also gitignored; the files inside are
`chmod 600`.

### SSH key and `~/.ssh/config`

Each `just az-up` drops the per-RG keypair under `.secrets/azure/<rg>/` and
prints a ready-to-paste `~/.ssh/config` block for a short alias:

```sshconfig
Host vpn-<rg>
    HostName vpn-xxxx.japaneast.cloudapp.azure.com
    User azureuser
    IdentityFile /abs/path/.secrets/azure/<rg>/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /abs/path/.secrets/azure/known_hosts
    StrictHostKeyChecking accept-new
```

`just az-down` removes that directory along with the resource group. Pass
`just az-down -y --keep-keys` to preserve it (e.g. to reconnect to a VM that
failed to provision cleanly but is still reachable).

## Client setup

Don't hand-copy fields — `just az-client` (or `scripts/client_config.py`) reads the vault and
emits client material for whatever `vpn_protocol` is deployed: a `vless://`
URL, an `xray-client.json`, a mihomo `clash.yaml` fragment, a complete local
`clash-verge.yaml`, a QR PNG and a field table.

### VLESS + REALITY (default) — Shadowrocket, v2rayN, v2rayNG, mihomo

- Address: your domain — **keep the FQDN**, not the bare IP, so `just az-rotate-ip` doesn't invalidate the config
- Port: `443`
- UUID: `vault_v2ray_uuid`. **Generate with `uuidgen`; do not reuse any example value from this repo.**
- Flow: `xtls-rprx-vision`
- Network: `tcp`, Security: `reality`
- SNI / servername: `reality_server_names[0]` (default `www.apple.com`) — **borrowed**, unrelated to the address you dial
- Public key / short ID: `vault_reality_public_key` / `vault_reality_short_id`
- Client fingerprint: `chrome`

### VMess over WebSocket (`vpn_protocol: vmess_ws` / `both`)

Same as before with one hard requirement: **AlterId must be `0`.** Xray-core dropped legacy
non-AEAD VMess, so a client still set to `64` cannot connect at all. In `both` mode the WS
listener is on `vmess_ws_port` (default `2053`), not 443.

### Clash-family clients (Windows, macOS, Linux)

Pick an open-source core plus an open-source shell — the core sees all your traffic:

| Role | Use |
|---|---|
| Core | [**mihomo**](https://github.com/MetaCubeX/mihomo) — the only Clash-family core here that speaks VLESS / Vision / REALITY |
| Desktop GUI | [**Clash Verge Rev**](https://github.com/clash-verge-rev/clash-verge-rev) — GPL-3.0, Tauri, embeds mihomo and switches cores from the UI. Windows / macOS 11+ / Linux. See the [local setup runbook](clients/clash-verge/README.md). |
| Mobile | [Clash Mi](https://github.com/KaringX/clashmi) / [FlClash](https://github.com/chen08209/FlClash) |
| Containerised | [`clients/mihomo-docker/`](clients/mihomo-docker/README.md) — its `config.example.yaml` carries a VLESS+REALITY proxy in the right shape |

For Clash Verge Rev, drag the generated `out/client/clash-verge.yaml` onto its Profiles
page. Use `vless.txt` for clients that accept URI import. Do not type the public key and
short ID by hand — one wrong character fails the handshake in a way that looks exactly
like being blocked.

**Clash for Windows and `Kuingsmile/clash-core` v1.18 are archived and cannot do REALITY.**
[`clients/clash-verge/README.md`](clients/clash-verge/README.md) covers the desktop setup,
import, verification, and duplicate-launcher diagnosis. [`clients/cli/README.md`](clients/cli/README.md)
keeps the old flow under a Legacy heading; [`clients/docker/`](clients/docker/README.md) is
that older core. Background: [`docs/clash/Clients.md`](docs/clash/Clients.md).

## Troubleshooting

- **Browser shows a TLS error on `https://$DOMAIN/`** → expected in `reality` mode. Your hostname isn't in `serverNames`, so the connection is forwarded to `reality_dest` and you get *its* certificate under the wrong name. `just verify` asserts this on purpose.
- **Ports 80/443 not open at cloud firewall** → nothing reachable; in `vmess_ws`/`both` the certbot bootstrap also stalls at the HTTP-01 challenge. Open them first, then `just deploy` again (idempotent). In `both` mode also open `vmess_ws_port`.
- **Deploy fails with "needs vault_reality_private_key …"** → the host's vault predates the REALITY migration. `just reality-keys --format vault-yaml` then `just vault-edit <rg>`, or `scripts/az_configure.py --force --rg <rg>`.
- **Xray container restarts on loop** → `just logs-xray-container`. The image is distroless, so `docker compose exec xray sh` does not exist; config and permission errors only surface in `docker logs`.
- **Old client stopped working after the upgrade** → it's probably pinned to `alterId: 64`. Xray-core only speaks VMess AEAD. Re-import from `just az-client`.
- **`502 Bad Gateway` at the WebSocket path** (`vmess_ws`/`both`) → Xray isn't running or nginx can't reach it. `just logs-xray-container` and `just ps`.
- **`400 Bad Request` at the WebSocket path in a browser** → expected. Xray rejects non-WebSocket GETs on that path; clients handshake correctly.
- **`cannot expose privileged port 80` during docker install** → you're in rootless mode. This project uses rootful Docker (`ansible/roles/docker/` and `scripts/install_docker.sh`). Reinstall fresh.
- **Cert stuck as dummy / self-signed** (`vmess_ws`/`both`) → LE bootstrap failed partway. Delete `/opt/vpn/runtime/certbot/conf/live/<domain>/` on the VPS and re-run `just deploy`. The role detects missing cert and re-bootstraps.
- **Client connects but no traffic flows** → `just verify-proxy` to isolate client vs server, then `just logs-xray` for inbound traces; confirm the client UUID, public key and short ID all match the vault.

## License

MIT.
