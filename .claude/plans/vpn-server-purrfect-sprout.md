# VPN Server IaC / Auto-Deploy Refactor Plan

## Context

`DockerCompose-V2Ray` is a stable personal V2Ray/Xray VPN server using Docker Compose. The current deploy flow on a new VM is tedious:

1. Create VPS (Azure / occasionally GCP) and open ports 80/443
2. Run `install_docker.sh` (which mixes rootful + rootless setup — conflicting)
3. Hand-edit `initial_https.sh` (domain + email) which `sed`-writes into `init-letsencrypt.sh` and `data/nginx/conf.d/v2ray.conf`
4. Hand-edit `data/v2ray/config.json` (UUID)
5. `mkdir logs/` (implicit — compose mounts this but no one creates it)
6. `docker compose up --build`
7. Verify manually via browser

Pain points:
- Default UUID `bae399d4-13a4-46a3-b144-4af2c0004c2e` is hardcoded in 4 places (server, 2 example client configs, README). Effectively a shared "secret."
- `sed` templating edits tracked files in place — re-running is destructive, recovery is `git reset --hard`.
- `.gitignore` only contains `.DS_Store`. `data/certbot/` (real TLS certs) and `logs/` could be accidentally committed.
- No `.env` file, no secrets hygiene.
- Template vs runtime state are the **same file**, so there's no clean distinction between "what's in the repo" and "what the running server has."
- `install_docker.sh` tries rootful and rootless simultaneously — broken.
- Repo mixes server + client tools + docs + examples at top level; two stale `_old` files; 40KB example config with duplicated UUID; `docs/` fragmented.

Intended outcome: a single-command deploy to a new VPS, idempotent re-runs, secrets out of the repo, and a cleaner directory layout. User confirmed this is a **large-scale refactor** and requested **old files be moved to a `legacy/` subfolder rather than deleted or overwritten**.

---

## Approach: **Ansible only** (confirmed)

Ansible orchestrates everything from a bare Ubuntu VPS onwards. Cloud-provider-agnostic (works for Azure, GCP, Hetzner — whatever you create the VM on). Not opinionated about VM creation — you still click-create the VM (~90s, not the pain point).

**Also confirmed:**
- **TLS-always** — no-TLS compose retired to `legacy/`, one template set, one code path.
- **Stay on V2Ray/VMess** — protocol migration not folded in; `docs/XrayUI.md` stays a future-consideration note.

**Not chosen (for reference):**
- *Lightweight `.env` + Justfile* — fixes local templating but still requires manual SSH+clone per new VM.
- *OpenTofu + Ansible* — pays per-provider module cost in exactly the area you're most fluid (swapping Azure/GCP). Can be added later as `infra/` if ever going multi-region + Azure-committed.

---

## Target repo layout

```
DockerCompose-V2Ray/
├── README.md                          # rewritten — one canonical path at top
├── Justfile                           # laptop-side commands (deploy, rotate-uuid, verify, logs)
├── .env.example                       # tracked template for server-side interpolation
├── .gitignore                         # expanded (see below)
│
├── server/                            # everything that runs on the VPS
│   ├── compose.yml                    # renamed from docker-compose.yml; uses ${VARS}
│   ├── templates/                     # tracked templates (truth source)
│   │   ├── nginx/v2ray.conf.tmpl
│   │   └── v2ray/config.json.tmpl
│   ├── static/                        # tracked static assets
│   │   └── nginx/html/v2ray/index.html
│   └── runtime/                       # gitignored; generated on deploy
│       ├── nginx/conf.d/
│       ├── v2ray/
│       ├── certbot/
│       └── logs/
│
├── ansible/
│   ├── ansible.cfg
│   ├── requirements.yml               # community.docker, etc.
│   ├── inventory/
│   │   ├── prod.ini
│   │   └── dev.ini                    # optional
│   ├── group_vars/
│   │   ├── all.yml                    # TZ, compose_mode, paths
│   │   └── all.vault.yml              # ansible-vault encrypted: UUID, EMAIL, DOMAIN
│   ├── playbooks/
│   │   ├── site.yml                   # full deploy (imports roles)
│   │   ├── deploy.yml                 # app-only redeploy (skip OS hardening)
│   │   └── rotate-uuid.yml
│   └── roles/
│       ├── common/                    # apt update, tz, ufw (22/80/443), fail2ban, unattended-upgrades
│       ├── docker/                    # rootful docker + compose plugin
│       ├── vpn/                       # compose files, templated configs, handlers
│       └── letsencrypt/               # certbot bootstrap
│
├── clients/                           # moved out of top level
│   ├── cli/                           # from client/ (setup_linux_clash_client.sh)
│   ├── docker/                        # from client_docker/ (Clash + YACD)
│   └── examples/                      # from example/ (client configs with placeholders)
│
├── docs/
│   ├── README.md                      # doc index
│   ├── architecture.md                # new — diagram of containers/ports/flows
│   ├── deploy.md                      # canonical deploy guide (points to Justfile)
│   ├── troubleshooting.md             # extracted from README
│   ├── FlowCharts.md                  # existing (Clash routing, Chinese)
│   └── XrayUI.md                      # existing
│
└── legacy/                            # ← user-requested: nothing deleted, just archived
    ├── README.md                      # explains what's here and why
    ├── scripts/
    │   ├── initial_https.sh           # old sed-based wrapper
    │   ├── init-letsencrypt.sh        # old certbot bootstrap
    │   └── install_docker.sh          # old rootful+rootless mix
    ├── compose/
    │   ├── docker-compose.yml                       # original filename preserved
    │   └── docker-compose-v2ray-without-tls.yml     # no-TLS mode retired here
    ├── clients/
    │   ├── setup_linux_clash_client_old.sh
    │   └── ui_pages_old/              # if present under client_docker/
    └── example/
        └── clash_for_windows.yml      # original 40KB version with default UUID
```

**Legacy policy**: Nothing from the current tree is deleted or overwritten in place. Files that are replaced by new equivalents are **moved (via `git mv`) into `legacy/`** so history follows them. `legacy/README.md` explains "these files are preserved for reference; the current deploy flow does not use them."

---

## Deploy flow after refactor

### One-time, on a new VPS

```bash
# 1. Create VPS in cloud portal/CLI. Open ports 80, 443, 22.
#    Point DNS (e.g. *.japaneast.cloudapp.azure.com) at the public IP.

# 2. On laptop, add VPS to inventory:
#    ansible/inventory/prod.ini
#    [vpn]
#    tokyo ansible_host=20.1.2.3 ansible_user=azureuser

# 3. Unlock secrets (one of):
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault-pass   # or use --ask-vault-pass

# 4. Deploy:
ansible-galaxy install -r ansible/requirements.yml
just deploy prod                                    # wraps ansible-playbook site.yml

# 5. Verify:
just verify prod                                    # curl https://$DOMAIN, check 200 + WS upgrade
```

### Redeploy after config change

```bash
just deploy prod                                    # idempotent; only changed tasks run
```

### Rotate UUID

```bash
just rotate-uuid prod                               # playbook generates new UUID, updates vault, reconfigures server
```

---

## Secrets handling

- `ansible/group_vars/all.vault.yml` — encrypted with `ansible-vault` (single password) or SOPS+age. Contains: `v2ray_uuid`, `letsencrypt_email`, `domain` (if you treat it as private).
- Vault password in macOS Keychain or 1Password CLI; `.vault-pass` file chmod 600, gitignored.
- `.env` on the server is **generated by Ansible at deploy time** from vault vars, not hand-edited.
- No secrets in the git repo at any commit.
- Default UUID `bae399d4-...` in existing commits — rotate and document in README that any new deploy must `uuidgen`. History scrub not worth it for a personal repo.

---

## Repo cleanup (applies regardless of which approach you end up using)

1. **Template/runtime split** — `data/nginx/conf.d/v2ray.conf` and `data/v2ray/config.json` move to `server/templates/` as `.tmpl`; the live `data/` paths become generated and gitignored. (Existing copies → `legacy/`.)
2. **Rename compose file** — Compose v2 convention: `docker-compose.yml` → `compose.yml`. No-TLS compose retired (not renamed). Originals → `legacy/compose/`.
3. **Separate server from clients** — `server/` and `clients/` top-level dirs.
4. **Retire `_old` files** — `client/setup_linux_clash_client_old.sh` and any `ui_pages_old/` → `legacy/clients/`.
5. **Strip default UUID** from `README.md`, `clients/docker/config.yaml`, `clients/examples/clash-for-windows.example.yml` — replace with `<YOUR_UUID>` placeholder. Original `example/clash_for_windows.yml` → `legacy/example/`.
6. **Fix `install_docker.sh`** — pick rootful (correct for ports 80/443). Old version → `legacy/scripts/`.
7. **Consider** `client_docker/clash-linux-386-v1.18.0.gz` — big binary in tree; either download in Dockerfile or Git LFS. Not blocking.
8. **`.gitignore` additions**:
   ```
   # secrets
   .env
   .vault-pass
   *.vault-pass

   # runtime state
   server/runtime/
   data/                   # during migration window
   logs/

   # ansible
   *.retry
   ansible/inventory/*.local.*

   # editor / OS
   .DS_Store
   .idea/
   .vscode/
   ```
9. **README restructure** — one canonical deploy path at top (`just deploy prod`). Move legacy prose to `docs/LEGACY.md` (linking into `legacy/`).

---

## Staged migration (recommended PR sequence)

Each PR independently valuable; if life gets busy after PR 2 you're still strictly better off.

- **PR 0 — Tag current state before any refactor.**
  - `git tag -a pre-iac-refactor -m "Last commit of the shell-script + docker-compose era before IaC refactor"`
  - `git push origin pre-iac-refactor`
  - Suggested tag name: `pre-iac-refactor` (or `v0-legacy`, `v1.0-legacy` — pick one and stick with it).
  - The new `README.md` will include a "Legacy version" section pointing at this tag:
    > The shell-script + raw Docker Compose deploy flow documented prior to the IaC refactor is preserved at tag [`pre-iac-refactor`](../../tree/pre-iac-refactor). Check out that tag or see [`docs/LEGACY.md`](docs/LEGACY.md) for the original instructions.
  - `docs/LEGACY.md` briefly recaps the old flow and also links to the tag + the `legacy/` folder.
  - **Effort: 2 minutes.** Do this before touching anything else.
- **PR 1 — Cleanup + reorganization, no IaC yet.**
  - Create `legacy/`; `git mv` `_old` files, old scripts, old compose files, original 40KB example config.
  - Reorganize dirs: `server/`, `clients/`.
  - Move `data/v2ray/config.json` and `data/nginx/conf.d/v2ray.conf` to `server/templates/*.tmpl` (keep working copies under `data/` for now so the existing `initial_https.sh` still functions during the transition).
  - Retire no-TLS compose into `legacy/compose/`.
  - Fix `.gitignore` (runtime dirs, secrets, IDE files).
  - Fix `install_docker.sh` (rootful only); old version to `legacy/scripts/`.
  - Scrub default UUID from tracked files (replace with `<YOUR_UUID>`); rotate live UUID.
  - Split README: canonical path + link to `docs/LEGACY.md` (which references tag and `legacy/`).
  - **Effort: ~1 evening. Zero functional risk — deploy flow still works via existing scripts.**
- **PR 2 — Ansible (the actual IaC migration).**
  - Scaffold `ansible/` with `common` (apt, ufw, fail2ban, unattended-upgrades, tz), `docker` (rootful install), `vpn` (compose + templated configs + handlers), `letsencrypt` (certbot bootstrap) roles.
  - Translate `server/templates/*.tmpl` → Jinja2 `.j2` files under each role.
  - Set up `group_vars/all.vault.yml` with `ansible-vault`; move UUID/email/domain there.
  - Laptop-side `Justfile` wrapping `ansible-playbook`: `just deploy`, `just verify`, `just rotate-uuid`, `just logs`.
  - `scripts/verify.sh` smoke test.
  - Test end-to-end on a throwaway VM before retiring the old flow.
  - **Effort: ~1 weekend if new to Ansible, ~4 hours if familiar.**
- **PR 3 (optional, much later) — OpenTofu `infra/azure/`** only if you later commit to Azure-only + multi-region.

---

## Verification

End-to-end checks on a throwaway VPS:

```bash
# After PR 1 (cleanup only) — existing manual flow must still work:
./legacy/scripts/install_docker.sh          # or the cleaned rootful version
cp server/compose.yml .                     # or keep old path during transition
# (existing initial_https.sh path continues to function)
curl -I https://$DOMAIN/                    # expect 200 "Congratulation!"
curl -I https://$DOMAIN/v2ray               # expect 400 "bad request" (V2Ray replying)

# After PR 2 (Ansible) — fresh Ubuntu 22.04 VM with only SSH open:
just deploy prod                            # zero-to-running from laptop
just verify prod                            # curl + WS handshake check
# Idempotency:
just deploy prod                            # second run: 0 changed tasks
# UUID rotation:
just rotate-uuid prod                       # then reconnect a client
```

Smoke script `scripts/verify.sh`:
- `curl -sSf https://$DOMAIN/` returns 200 with "Congratulation!" body
- WebSocket upgrade to `https://$DOMAIN/v2ray` returns 400 (means V2Ray is handling it)
- No `error.log` entries newer than deploy timestamp
- `docker compose ps` shows all services `healthy`/`running`

---

## Remaining minor decisions (not blocking — can settle during implementation)

1. **Rootful Docker** — going with rootful (correct for binding ports 80/443 on a single-user VM). The rootless attempt in the current `install_docker.sh` is the source of several footguns; retiring it.
2. **Vault password storage** — either macOS Keychain, 1Password CLI, or `~/.vault-pass` (chmod 600). Decide when scaffolding `ansible/`.
3. **DNS management** — out of scope. Azure auto-provides `*.cloudapp.azure.com`; if you ever use a custom domain that's a separate, later PR.
4. **YACD submodule** (`client_docker/hinak0_yacd`) — keep as-is for now; not on the critical path.
5. **`clash-linux-386-v1.18.0.gz`** (~5MB binary in tree) — defer; can be moved to Dockerfile `wget` or Git LFS later.
6. **Chinese-language docs** — unchanged (intentional).

---

## Critical files to modify/reference

- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/docker-compose.yml` → becomes `server/compose.yml` (original to `legacy/compose/`)
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/docker-compose-v2ray-without-tls.yml` → retired to `legacy/compose/` (TLS-always confirmed)
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/initial_https.sh` → replaced by Ansible task; original to `legacy/scripts/`
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/init-letsencrypt.sh` → replaced by `letsencrypt` role; original to `legacy/scripts/`
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/install_docker.sh` → replaced by `docker` role; cleaned shell version (rootful only) stays in `scripts/`; original to `legacy/scripts/`
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/data/nginx/conf.d/v2ray.conf` → becomes `server/templates/nginx/v2ray.conf.tmpl` + Jinja `.j2` in role; original to `legacy/`
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/data/v2ray/config.json` → becomes `server/templates/v2ray/config.json.tmpl` + Jinja `.j2`; original to `legacy/`
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/.gitignore` → expanded
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/README.md` → rewritten; legacy prose to `docs/LEGACY.md`
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/client/setup_linux_clash_client_old.sh` → `legacy/clients/`
- `/Volumes/Data/Program/Personal/DockerCompose-V2Ray/example/clash_for_windows.yml` → `legacy/example/` + stripped version in `clients/examples/`
