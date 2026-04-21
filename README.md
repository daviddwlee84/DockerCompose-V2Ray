# DockerCompose-V2Ray

A personal V2Ray (VMess over WebSocket) VPN server, deployed via Ansible. Nginx reverse proxy terminates TLS (Let's Encrypt, auto-renewing) and forwards WebSocket traffic to V2Ray.

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
$EDITOR ansible/group_vars/vpn/vault.yml                      # fill domain, email, uuid
just vault-encrypt
echo 'your-vault-password' > ~/.vault-pass && chmod 600 ~/.vault-pass
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault-pass

# Deploy:
just deploy                                                   # ~5 min first run
DOMAIN=your.domain.tld just verify                            # smoke-test
```

What `just deploy` does: installs rootful Docker, hardens the OS (ufw, fail2ban, unattended-upgrades, timezone), renders server configs from Jinja2 templates + vault secrets, bootstraps Let's Encrypt via HTTP-01, and brings up the Docker Compose stack.

Re-deploy after config edits: `just deploy-fast` (skips OS/Docker steps, just re-renders configs and reloads services). Rotate the UUID: `just rotate-uuid`.

See [`ansible/README.md`](ansible/README.md) for details (role structure, vault layout, rotating secrets).

> Prefer the old shell-script flow? It's frozen at the [`pre-iac-refactor`](../../tree/pre-iac-refactor) tag. See [`docs/LEGACY.md`](docs/LEGACY.md).

## Repo layout

| Path | Purpose |
|---|---|
| `server/` | Everything that ends up on the VPS: `compose.yml`, `templates/` (source-of-truth configs with placeholders), `static/` (landing page), `runtime/` (generated at deploy time, gitignored). |
| `ansible/` | Playbooks, roles (`common`, `docker`, `vpn`, `letsencrypt`), inventory, vault. |
| `scripts/` | `install_docker.sh` (rootful bootstrap), `verify.sh` (smoke test). |
| `Justfile` | Laptop-side wrapper: `deploy`, `deploy-fast`, `rotate-uuid`, `verify`, `logs-*`, `vault-edit`. |
| `clients/cli/` | CLI Clash client setup for Linux. |
| `clients/docker/` | Dockerized Clash proxy + YACD dashboard (git submodule) for local testing. |
| `docs/` | `DeploymentEvaluation.md` + `BareMetalEvaluation.md` (why Ansible + Docker Compose, not Terraform + systemd), `IP-ROTATION.md` (rotate a GFW-banned Azure IP while keeping the FQDN), `LEGACY.md` (pre-refactor flow), `old/` (archived notes: `FlowCharts.md` Clash routing, `XrayUI.md` alt admin panels). |
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
just az-configure     # render inventory/prod.ini + encrypted vault.yml
just deploy           # existing ansible flow (common + docker + vpn + letsencrypt)
DOMAIN=$(jq -r .fqdn .secrets/azure/last-vm.json) just verify
just az-client        # emit out/client/{vmess.txt,config.json,clash.yaml,human.md,qr.png}
just az-rotate-ip     # rotate the public IP, keep the FQDN (use when GFW-banned; see docs/IP-ROTATION.md)
just az-down -y       # delete the RG (-y skips the type-the-name confirm)

# Or the whole loop in one shot, with a pause for manual testing before teardown:
AZ_YES=1 just az-cycle
```

`scripts/az_up.sh` queries the Azure Retail Prices API and shows an
hourly / daily / monthly estimate for the target (region, VM size) before
prompting; set `AZ_YES=1` to skip the confirm prompt. It also configures a
DevTest-Labs daily auto-shutdown at `AZ_SHUTDOWN_TIME` (default `1800` UTC ≈
02:00 Asia/Shanghai) as a safety net for forgotten VMs — set
`AZ_SHUTDOWN_TIME=off` to disable.

Other overrides (all env vars read by `scripts/az_up.sh`): `AZ_LOCATION`,
`AZ_VM_SIZE`, `AZ_VM_NAME`, `AZ_DNS_PREFIX`, `AZ_SSH_PUBKEY`, `AZ_RG`,
`AZ_IMAGE`, `AZ_ADMIN_USER`, `AZ_OVERWRITE`. Let's Encrypt email falls back
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

### VMess client config (Shadowrocket, v2rayN, etc.)

- Address: your domain
- Port: `443`
- UUID: whatever you set as `vault_v2ray_uuid`. **Generate with `uuidgen`; do not reuse any example value from this repo.**
- AlterId: `64`
- Security: `auto`
- TLS: enabled (allow-insecure only if you're using a staging cert while iterating)
- Transport: WebSocket, path `/v2ray`

### Clash (Windows, macOS, Linux)

See [`clients/docker/config.yaml`](clients/docker/config.yaml) for a working Clash config — edit `server:` and `uuid:` to point at your deploy. For a containerized local proxy + YACD dashboard, see [`clients/docker/README.md`](clients/docker/README.md). For a Linux CLI-only setup, see [`clients/cli/README.md`](clients/cli/README.md).

## Troubleshooting

- **Ports 80/443 not open at cloud firewall** → certbot bootstrap stalls at the HTTP-01 challenge. Open them first, then `just deploy` again (idempotent).
- **`502 Bad Gateway` at `https://$DOMAIN/v2ray`** → V2Ray container isn't running or nginx can't reach it. `just logs-v2ray` and `just ps`.
- **`400 Bad Request` at `https://$DOMAIN/v2ray` in a browser** → expected. V2Ray rejects non-WebSocket GETs on that path; clients handshake correctly.
- **`cannot expose privileged port 80` during docker install** → you're in rootless mode. This project uses rootful Docker (`ansible/roles/docker/` and `scripts/install_docker.sh`). Reinstall fresh.
- **Cert stuck as dummy / self-signed** → LE bootstrap failed partway. Delete `/opt/vpn/runtime/certbot/conf/live/<domain>/` on the VPS and re-run `just deploy`. The role detects missing cert and re-bootstraps.
- **Client connects but no traffic flows** → `just logs-v2ray` for inbound traces; confirm client UUID matches `vault_v2ray_uuid`.

## License

MIT.
