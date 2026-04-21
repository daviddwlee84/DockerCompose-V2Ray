# ansible/

Provider-agnostic deploy for the VPN server. Runs from your laptop against a fresh Ubuntu VPS reachable by SSH.

## Prerequisites

On your laptop:

```bash
brew install ansible just          # or: pipx install ansible-core && brew install just
ansible-galaxy install -r ansible/requirements.yml
```

On the VPS: nothing — just SSH access as a user with passwordless sudo, and ports 22/80/443 open at the cloud firewall.

## First-time setup

1. **Copy inventory example:**
   ```bash
   cp ansible/inventory/prod.ini.example ansible/inventory/prod.ini
   vim ansible/inventory/prod.ini                # add your host
   ```
2. **Copy vault example and fill in values:**
   ```bash
   cp ansible/group_vars/vpn/vault.yml.example ansible/group_vars/vpn/vault.yml
   vim ansible/group_vars/vpn/vault.yml          # fill domain, email, uuid
   ```
3. **Encrypt the vault:**
   ```bash
   ansible-vault encrypt ansible/group_vars/vpn/vault.yml
   ```
4. **Store the vault password where Ansible can find it:**
   ```bash
   echo 'yourpassword' > ~/.vault-pass
   chmod 600 ~/.vault-pass
   export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault-pass
   ```
   Or pass `--ask-vault-pass` each run.

## Deploy

From the repo root:

```bash
just deploy                # full: common + docker + vpn + letsencrypt
just deploy-fast           # just vpn role (use after config tweaks)
just verify                # smoke-test the running deploy
just rotate-uuid           # generate a new UUID, update vault, redeploy vpn role
```

Or directly:

```bash
cd ansible
ansible-playbook playbooks/site.yml
ansible-playbook playbooks/deploy.yml             # vpn-only, faster
ansible-playbook playbooks/rotate-uuid.yml -e new_uuid=$(uuidgen)
```

## Layout

- `ansible.cfg` — inventory path, SSH multiplexing, YAML output.
- `requirements.yml` — Ansible collections (`community.docker`, `ansible.posix`, `community.general`).
- `inventory/` — `prod.ini.example` and `dev.ini.example`; real `prod.ini`/`dev.ini` are gitignored.
- `group_vars/all.yml` — non-secret defaults (tz, deploy path, ports).
- `group_vars/vpn/vars.yml` — per-group indirection: `domain: "{{ vault_domain }}"`.
- `group_vars/vpn/vault.yml` — encrypted secrets (gitignored unless encrypted).
- `playbooks/site.yml` — full deploy (all roles in order).
- `playbooks/deploy.yml` — app-only, for config tweaks.
- `playbooks/rotate-uuid.yml` — rotate V2Ray UUID.
- `roles/`
  - `common/` — OS hardening: apt update, timezone, ufw, fail2ban, unattended-upgrades.
  - `docker/` — rootful Docker install + compose plugin + user in docker group.
  - `vpn/` — renders server config from Jinja2 templates, syncs compose files, `docker compose up -d`.
  - `letsencrypt/` — bootstraps Let's Encrypt HTTP-01 cert on first deploy (subsequent deploys are no-ops since certbot sidecar auto-renews).

## Secrets

Anything under `group_vars/vpn/vault.yml` is encrypted with `ansible-vault`. Plain values never land in git. If you accidentally commit an unencrypted vault.yml, rotate the UUID immediately and scrub with `git filter-repo`.
