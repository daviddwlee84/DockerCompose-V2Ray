# DockerCompose-V2Ray

A personal V2Ray (VMess over WebSocket) VPN server, deployed via Ansible. Nginx reverse proxy terminates TLS (Let's Encrypt, auto-renewing) and forwards WebSocket traffic to V2Ray.

## Deploy

On a fresh Ubuntu VPS with SSH open and ports 22/80/443 reachable at the cloud firewall, pointed at by your domain:

```bash
# On laptop, one-time setup:
brew install ansible just                                     # or pipx install ansible-core
just galaxy                                                   # install ansible collections
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
| `docs/` | `FlowCharts.md` (Clash routing), `XrayUI.md` (alt admin panels), `LEGACY.md` (pre-refactor flow). |
| `legacy/` | Archived pre-refactor files. Nothing here is used by the current flow. See [`legacy/README.md`](legacy/README.md). |

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
