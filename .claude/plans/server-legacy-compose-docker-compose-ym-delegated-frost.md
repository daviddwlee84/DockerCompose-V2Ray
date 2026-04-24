# Plan — Log retention for nginx/v2ray on the VPN VPS

## Context

The VPS is running out of disk because nginx (`access.log` + `error.log`) and v2ray (`access.log` + `error.log`) write unbounded to mounted host directories:

```
/opt/vpn/runtime/logs/nginx   # 252M observed
/opt/vpn/runtime/logs/v2ray   # 146M observed
```

No rotation exists anywhere in the repo today (confirmed by grep: no `logrotate`, no `logging:`, no `max-size`). Eventually fills the root FS — the user hit `No space left on device` trying to create a tmux socket.

The user referenced `legacy/compose/docker-compose.yml`, but per `CLAUDE.md` the active deploy path is Ansible (`server/compose.yml` / `ansible/roles/vpn/templates/compose.yml.j2`). Legacy mounts logs the same way, but we only fix the active path — `legacy/` is archival, don't touch.

**Chosen approach** (confirmed with user): host-side `logrotate` with `copytruncate`, 7 days retention, 20M size cap, gzip compression. Selected over the Docker `json-file` logging driver route because it keeps `just logs-v2ray` / `just logs-nginx` working (they `tail` host files) and requires no changes to nginx / v2ray / compose templates.

## Why `logrotate` + `copytruncate`

- **`copytruncate`** copies the file then truncates the original → file inode is preserved → nginx and v2ray keep writing to the same open FD without needing a reload/signal. No `docker exec nginx -s reopen`, no v2ray SIGUSR-whatever.
- Trade-off: a small window of writes mid-copy may be lost. Acceptable for a personal VPN's access logs — not financial audit trails.
- Ubuntu Server ships `logrotate` pre-installed with `/etc/cron.daily/logrotate` already wired up. Nothing to install, no cron to schedule — just drop a config into `/etc/logrotate.d/`.
- `maxsize 20M` means logrotate will rotate mid-day if a single file exceeds 20M, not only at the daily cron tick. Protects against burst growth between daily runs.

## Changes

### 1. New file: `ansible/roles/vpn/templates/logrotate-vpn.conf.j2`

```
# Managed by Ansible — edits on the VPS will be overwritten.
/opt/vpn/runtime/logs/nginx/*.log
/opt/vpn/runtime/logs/v2ray/*.log {
    daily
    rotate 7
    maxsize 20M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
```

Notes:
- Both path globs share one stanza — rotation policy is identical for both services.
- `missingok` → config stays valid on a freshly-provisioned VPS where the log files don't exist yet (e.g. between `common`/`docker` roles running and the `vpn` stack first starting).
- `notifempty` → skip rotating empty files (no clutter).
- `delaycompress` → rotate `.1` stays uncompressed for one cycle so operators can still `zcat`-free-tail the most recent rotation if needed.

### 2. Edit: `ansible/roles/vpn/tasks/main.yml`

Add a task after the existing log-directory creation tasks (`ansible/roles/vpn/tasks/main.yml:21-22`, per Phase 1 exploration):

```yaml
- name: Install logrotate config for nginx + v2ray logs
  ansible.builtin.template:
    src: logrotate-vpn.conf.j2
    dest: /etc/logrotate.d/vpn
    owner: root
    group: root
    mode: "0644"
  become: true
```

Rationale for placing in `vpn` role (not `common`): the rotated paths are VPN-specific (`/opt/vpn/runtime/logs/...`) and the `vpn` role already owns those directories. `common` is for generic OS hardening per the existing role split.

No `apt install logrotate` task needed — logrotate is Priority: important on Ubuntu Server and always present.

## Files touched

- **NEW** `ansible/roles/vpn/templates/logrotate-vpn.conf.j2`
- **EDIT** `ansible/roles/vpn/tasks/main.yml` — add one `template:` task

No changes to:
- `ansible/roles/vpn/templates/compose.yml.j2` — log mounts stay as-is
- `ansible/roles/vpn/templates/nginx/*.j2` — no `access_log` / `error_log` directives to add
- `ansible/roles/vpn/templates/v2ray/config.json.j2` — log paths stay
- `Justfile` — `logs-v2ray` / `logs-nginx` still `tail` host files; `copytruncate` preserves the inode so they keep working
- `server/compose.yml`, `server/templates/` — no source-of-truth template change needed (logrotate is not part of the compose stack)
- `legacy/` — untouched per CLAUDE.md archival policy

## Verification

Local (before deploy):
```sh
# Template syntax is simple enough, but double-check Ansible renders it:
ansible-playbook --syntax-check ansible/playbooks/site.yml
```

Deploy:
```sh
just deploy-fast   # vpn role only — this picks up the new template + task
```

On the VPS (SSH via `just logs-*` inventory or directly):
```sh
# Config landed
sudo cat /etc/logrotate.d/vpn

# Dry-run shows logrotate parses it and picks up the files
sudo logrotate -d /etc/logrotate.d/vpn

# Force a rotation and verify outputs
sudo logrotate -f /etc/logrotate.d/vpn
ls -lh /opt/vpn/runtime/logs/nginx/    # expect access.log.1 (uncompressed, delaycompress)
ls -lh /opt/vpn/runtime/logs/v2ray/    # expect access.log.1, error.log.1

# Run it a second time to confirm .1 becomes .2.gz
sudo logrotate -f /etc/logrotate.d/vpn
ls -lh /opt/vpn/runtime/logs/nginx/    # expect access.log.2.gz etc.
```

Post-rotation sanity:
```sh
# just logs-* still work (tail survives copytruncate)
just logs-nginx
just logs-v2ray

# Services still writing (inode preserved)
just ps
# Generate some traffic and confirm access.log size > 0
```

Cleanup of the backlog the user is currently sitting on (one-time, manual — not part of the Ansible change):
```sh
# After rotation config is installed, trigger once to drain the 252M/146M backlog
sudo logrotate -f /etc/logrotate.d/vpn
du -sh /opt/vpn/runtime/logs/*
```
