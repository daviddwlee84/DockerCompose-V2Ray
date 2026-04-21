# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Personal V2Ray (VMess over WebSocket) VPN server for a single operator. Nginx reverse-proxies TLS to V2Ray on one Ubuntu VPS; Let's Encrypt certs auto-renew via a certbot sidecar. Deploy is Ansible-based, run from the operator's laptop. No multi-host setup, no CI, no shared infrastructure.

## Common commands

All from the repo root, all via `just` (see `Justfile`). `ANSIBLE_OPTS='--ask-vault-pass'` or `export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault-pass` to unlock the vault.

- `just galaxy` — one-time: install ansible collections (`community.docker`, `community.general`, `ansible.posix`).
- `just deploy` — full deploy (`common` + `docker` + `vpn` + `letsencrypt` roles via `ansible/playbooks/site.yml`). Use on a fresh VPS.
- `just deploy-fast` — `vpn` role only. Use after template / config tweaks.
- `just rotate-uuid` — generate a new UUID and redeploy with it. Does NOT update the vault file; see `ansible/playbooks/rotate-uuid.yml` for the manual follow-up.
- `DOMAIN=… just verify` — smoke test: 200 on `/`, 400 on `/v2ray` (= V2Ray handling), valid TLS chain.
- `just logs-v2ray` / `just logs-nginx` / `just ps` — ad-hoc one-liners against the live VPS.
- `just vault-edit` / `just vault-encrypt` — wrappers for `ansible-vault` on `ansible/group_vars/vpn/vault.yml`.

Local test harness (Ubuntu container, not a real VPS — see scope below):

- `just test-setup` — generate a throwaway SSH keypair under `test/ssh/` (one-time).
- `just test-up` / `just test-ping` / `just test-down`.

## Architecture

### Two-layer deploy: laptop runs Ansible → Ansible SSHes into VPS

Nothing is cloned onto the VPS. Files are synced (rsync via `ansible.posix.synchronize`) or rendered (Jinja2 `.j2` in the `vpn` role) from the laptop into `/opt/vpn/` on the target.

### Template / runtime split — don't step on this

`server/` is the source-of-truth for what runs on the VPS:

- `server/templates/*.tmpl` — **tracked**. Truth-source templates with `${VAR}` placeholders. These are mirrored by Jinja2 `.j2` files in `ansible/roles/vpn/templates/` which is what actually gets rendered on the VPS.
- `server/static/` — tracked static assets (currently just the nginx landing page).
- `server/runtime/` — **gitignored, generated at deploy time**. Never edit — overwritten on next `just deploy`.

Same pattern on the VPS: `/opt/vpn/{compose.yml,static/,runtime/}`. `runtime/` is always regenerated.

If a config needs parameterization, change both the `.tmpl` (source-of-truth for humans) AND the `.j2` (what Ansible actually uses). They're kept in lockstep on purpose.

### Secrets: `vars.yml` → `vault.yml` indirection

`ansible/group_vars/vpn/vars.yml` aliases plain names to `vault_*` values:

```yaml
domain: "{{ vault_domain }}"
v2ray_uuid: "{{ vault_v2ray_uuid }}"
```

All templates reference plain names (`{{ domain }}`, never `{{ vault_domain }}`). Templates therefore don't know or care whether a value came from the vault. **When adding a new secret, add to both `vault.yml` (encrypted) and `vars.yml` (alias).**

`vault.yml` is gitignored as defense-in-depth; commit it only after `ansible-vault encrypt` (`just vault-encrypt`).

### Let's Encrypt bootstrap — coordinated across two roles

Chicken-and-egg: nginx needs a cert to listen on 443; certbot needs nginx on 80 to solve HTTP-01; the template references a cert path that doesn't exist on a fresh host.

Resolution (two roles, strict order):

1. `vpn` role (runs first) checks whether `runtime/certbot/conf/live/$DOMAIN/fullchain.pem` exists. If yes → renders the full nginx conf. If no → renders `acme-only.conf.j2` (port 80 only, no SSL block).
2. `letsencrypt` role (runs after) brings up nginx alone with that ACME-only conf, runs a one-shot `certbot --webroot`, re-renders the full nginx conf, brings up the full compose stack (with the certbot renewal sidecar).

Don't reorder `vpn` and `letsencrypt` in `site.yml`. Subsequent deploys (cert present) are near no-ops on both.

### `legacy/` folder policy

Everything pre-refactor is preserved in-tree under `legacy/` (scripts, compose files, original configs, `_old` files). **Nothing here is used by the current deploy path.** The same state is also reachable via `git checkout pre-iac-refactor`. `docs/LEGACY.md` explains the old flow.

Rule: don't delete `legacy/` content, don't re-introduce it into active paths. When a refactor supersedes a file, `git mv` it into `legacy/` rather than deleting — history follows, and the archive stays browsable.

### Local test harness scope (`test/`)

Ubuntu 24.04 Docker container with SSH + passwordless-sudo `ansible` user. Validates:

- SSH / inventory wiring (`just test-ping`).
- `apt` tasks from the `common` / `docker` roles (the image uses an HTTP Tsinghua mirror for apt so it bootstraps even when `ports.ubuntu.com` is unreachable).
- Jinja2 template rendering.

Does NOT validate: systemd (no systemd in container), docker-in-docker (no `dockerd`), Let's Encrypt bootstrap (no real DNS / port 80). Those still need a real Ubuntu VPS.

The mirror-swap approach (vs injecting a host proxy via Docker config) is deliberate: a test harness for a VPN project cannot depend on the VPN being up. If Tsinghua is unreachable, swap to another mirror in `test/Dockerfile` — `mirrors.ustc.edu.cn`, `mirror.sjtu.edu.cn`, `mirrors.aliyun.com` — noting the `ubuntu-ports` vs `ubuntu` path difference between arm64 and amd64.

## Design constraints (decided — don't re-litigate)

- **Ansible only.** Not OpenTofu / Terraform. Operator moves between cloud providers (Azure, GCP, Hetzner); VM creation is click-ops and not the pain point. Config management is.
- **TLS always.** The no-TLS compose flow was retired to `legacy/compose/`. Don't re-add a conditional.
- **V2Ray / VMess.** Protocol migration to Xray/VLESS is explicitly out of scope. `docs/XrayUI.md` is a future-considerations note.
- **Rootful Docker.** Rootless + port 80/443 needs `setcap` on `rootlesskit` — extra friction for zero gain on a single-operator VPS.

## Workflow preferences

- Personal repo: prefer `git merge --ff-only` + delete branch over opening PRs. `git push origin master` is a separate, explicit step — not the default after a merge.
- On large refactors, move superseded files to `legacy/` via `git mv` and tag the pre-refactor state (see `pre-iac-refactor`). Don't delete or overwrite in place.
