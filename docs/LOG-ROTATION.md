# Log rotation

Nginx and V2Ray write `access.log` / `error.log` to mounted host directories
under `/opt/vpn/runtime/logs/{nginx,v2ray}/`. Without rotation they grow
unbounded and eventually fill the root FS (symptom: `No space left on device`
on `tmux`, `apt`, `docker`, anything).

The Ansible `vpn` role drops `/etc/logrotate.d/vpn` on every deploy.
Ubuntu's pre-installed `/etc/cron.daily/logrotate` picks it up from there —
no cron to schedule, no sidecar to run.

## TL;DR — on a fresh VPS

Already handled by `just deploy` / `just deploy-fast`. Nothing to do.

## TL;DR — patch an already-running VPS without re-deploying

Useful when you've got a live server you don't want to re-Ansible right now
(e.g. disk already 100% full, or VPS predates the repo change). One SSH
session, ~10 seconds:

```bash
ssh <user>@<vps>

# 1. Drop the logrotate config
sudo tee /etc/logrotate.d/vpn > /dev/null <<'EOF'
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
EOF

# 2. Dry-run — confirms logrotate parses it and sees the files
sudo logrotate -d /etc/logrotate.d/vpn

# 3. Force-rotate once to drain the existing backlog
sudo logrotate -f /etc/logrotate.d/vpn
du -sh /opt/vpn/runtime/logs/*
```

From here `/etc/cron.daily/logrotate` (already wired up on any Ubuntu Server)
takes over — no further action.

The next `just deploy` / `just deploy-fast` will overwrite
`/etc/logrotate.d/vpn` with the template-rendered version, which is
byte-identical to the above — safe to run, no config drift.

## What the config does

| Directive | Effect |
|-----------|--------|
| `daily` | Rotate once per day (triggered by `/etc/cron.daily/logrotate`). |
| `rotate 7` | Keep 7 historical files; the 8th is deleted. |
| `maxsize 20M` | Rotate mid-day if any one file exceeds 20M (protects against burst growth). |
| `compress` + `delaycompress` | gzip rotated files, but keep `.1` uncompressed one cycle so operators can tail it without `zcat`. |
| `copytruncate` | Copy the file then truncate the original → inode preserved → nginx/v2ray keep writing to the same FD without reload/signal. |
| `missingok` | No error if the path glob is empty (e.g. fresh VPS before first request). |
| `notifempty` | Skip rotating empty files. |

## Footguns

- **Disk already at 100%.** `logrotate -f` needs free space to write the
  rotated copy. If `df -h /` shows 0 available, buy yourself room first:
  ```bash
  sudo truncate -s 0 /opt/vpn/runtime/logs/nginx/access.log
  sudo truncate -s 0 /opt/vpn/runtime/logs/nginx/error.log
  sudo truncate -s 0 /opt/vpn/runtime/logs/v2ray/access.log
  sudo truncate -s 0 /opt/vpn/runtime/logs/v2ray/error.log
  ```
  `truncate -s 0` preserves the inode (same as copytruncate) — nginx and
  v2ray keep writing, current log contents are lost but future writes are
  fine. Then re-run step 3.

- **`copytruncate` loses mid-copy writes.** A small window between `cp` and
  `truncate` can drop a few log lines. Acceptable for a personal VPN; not
  for anything audited. Alternative (not used here): `postrotate` with
  `docker kill -s USR1 nginx` and equivalent for v2ray — more moving parts
  for no real benefit in this project.

- **`just logs-v2ray` / `just logs-nginx` right after rotation.** These
  `tail -n 50` the live file. Immediately after a rotation the file is
  near-empty, so tail will look quiet — not a bug. Check `access.log.1`
  (uncompressed) or `access.log.2.gz` for recent history:
  ```bash
  ssh <vps> 'sudo tail -n 50 /opt/vpn/runtime/logs/nginx/access.log.1'
  ssh <vps> 'sudo zcat /opt/vpn/runtime/logs/nginx/access.log.2.gz | tail -n 50'
  ```

- **Docker `logging.options.max-size` would NOT have worked here.** Nginx
  and v2ray write to files inside the container (not stdout), and the
  host-mounted volume shadows nginx's default `/var/log/nginx → /dev/stdout`
  symlink. The Docker logging driver only captures container stdout/stderr,
  so it would rotate the empty `docker logs` stream while the real files
  kept growing. Host-side logrotate is the right tool for this mount layout.

## Verification

After force-rotating once:

```bash
ls -lh /opt/vpn/runtime/logs/nginx/
# expected:
#   access.log        (0 bytes or small, actively being written)
#   access.log.1      (uncompressed — delaycompress keeps the most recent uncompressed)
#   error.log  /  error.log.1   likewise

# Run it a second time to confirm compression kicks in:
sudo logrotate -f /etc/logrotate.d/vpn
ls -lh /opt/vpn/runtime/logs/nginx/
# expected: access.log.2.gz now exists, access.log.1 is fresh uncompressed

# Services still writing to the same inode:
sudo lsof /opt/vpn/runtime/logs/nginx/access.log  # should show the nginx container process
```
