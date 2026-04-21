# DockerCompose-V2Ray

A personal V2Ray (VMess over WebSocket) VPN server, packaged as Docker Compose + Nginx reverse proxy + Let's Encrypt TLS.

> **Refactor in progress.** This repo is migrating from the shell-script + Docker Compose deploy flow to Ansible-based IaC. PR 1 (this commit) reorganized the layout and archived the old flow; PR 2 will add the Ansible playbook. Until PR 2 lands, use the legacy flow via the [`pre-iac-refactor`](../../tree/pre-iac-refactor) tag — see [`docs/LEGACY.md`](docs/LEGACY.md).

## Deploy (target flow, coming in PR 2)

On a fresh Ubuntu VPS with SSH open and ports 80/443 exposed:

```bash
# On laptop:
ansible-galaxy install -r ansible/requirements.yml
ansible-playbook -i ansible/inventory/prod.ini ansible/playbooks/site.yml --ask-vault-pass
```

That single command installs Docker (rootful), hardens the box (ufw, fail2ban, unattended-upgrades), renders server configs from Jinja2 templates + vault secrets, bootstraps Let's Encrypt, and brings up the compose stack.

### Deploy (current, manual — until PR 2 lands)

```bash
git checkout pre-iac-refactor
# Follow the README at that tag.
```

Or see [`docs/LEGACY.md`](docs/LEGACY.md) for a recap.

## Repo layout

| Path | Purpose |
|---|---|
| `server/` | Everything that runs on the VPS. `compose.yml` + `templates/` (truth source) + `static/` (unchanging assets) + `runtime/` (generated, gitignored). |
| `ansible/` | **Coming in PR 2.** Playbooks, roles, inventory, vault. |
| `scripts/` | Laptop-side or one-off bootstrap scripts. Currently just `install_docker.sh` (rootful). |
| `client/` | CLI client setup (Linux Clash). |
| `client_docker/` | Dockerized Clash client for local testing + YACD dashboard submodule. |
| `docs/` | `FlowCharts.md` (Clash routing logic), `XrayUI.md` (alt admin panels), `LEGACY.md` (pre-refactor flow). |
| `legacy/` | Archived pre-refactor files (scripts, compose, configs, examples). Nothing here is used by the current flow. See [`legacy/README.md`](legacy/README.md). |

## Client setup

### Vmess client config (e.g. Shadowrocket, v2rayN)

- Address: your domain (e.g. `yourhost.japaneast.cloudapp.azure.com`)
- Port: `443`
- UUID: whatever you put in the server config (generate with `uuidgen`; **do not** reuse any example value from this repo)
- AlterId: `64`
- Security: `auto`
- TLS: enabled, allow-insecure if needed
- Transport: WebSocket, path `/v2ray`

### Clash (for Windows, macOS, Linux)

See [`client_docker/config.yaml`](client_docker/config.yaml) for a minimal working Clash config — edit `server:` and `uuid:` to point at your own deploy.

For a dockerized local proxy + YACD dashboard, see [`client_docker/README.md`](client_docker/README.md).

For a Linux CLI setup, see [`client/README.md`](client/README.md).

## Troubleshooting

- **Ports 80/443 not open** → certbot bootstrap fails. Open them in the cloud firewall / NSG first.
- **502 at `https://$DOMAIN/v2ray`** → V2Ray container isn't running or nginx can't reach it. Check `server/runtime/logs/v2ray/error.log` and `docker compose ps`.
- **`bad request` at `https://$DOMAIN/v2ray`** → V2Ray is handling the WebSocket upgrade correctly. This is expected when you hit the path in a plain browser.
- **Rootless Docker + port 80/443 binding errors** → the refactor uses **rootful** Docker (`scripts/install_docker.sh`). If you see `cannot expose privileged port 80`, you're in rootless mode — reinstall with the rootful script.
- **Client connects but traffic doesn't flow** → check `server/runtime/logs/v2ray/access.log` for inbound requests, then verify UUID matches between client and server.

## License

MIT.
