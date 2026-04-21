# Bare-metal + systemd vs Docker Compose

Evaluation of running nginx + V2Ray + certbot directly on the Ubuntu host
under systemd, instead of the current
[`server/compose.yml`](../server/compose.yml) stack. This is the runtime-layer
counterpart to [DeploymentEvaluation.md](DeploymentEvaluation.md).

**Decision: stay on rootful Docker Compose.** The sections below show the
work, not because the decision is close, but so that a future reader (or the
operator after a year away from the repo) can see what was considered.

## What "bare metal" would look like here

Three systemd units replacing the three compose services:

- **`v2ray.service`** — install the upstream binary (official install
  script or a pinned GitHub release), read config from `/etc/v2ray/config.json`
  (currently rendered to `runtime/v2ray/config.json`), log to
  `/var/log/v2ray/`.
- **`nginx.service`** — distro package (`apt install nginx`), site configs
  under `/etc/nginx/conf.d/` (currently rendered to
  `runtime/nginx/conf.d/v2ray.conf`), logs to `/var/log/nginx/` with the
  distro's logrotate rules.
- **`certbot.timer`** — `apt install certbot python3-certbot-nginx` (or snap),
  webroot `/var/www/certbot/`, auto-renewal via the packaged systemd timer
  instead of a sidecar container loop.

The Ansible `vpn` role would change shape but not concept:

- [`ansible/roles/vpn/tasks/main.yml`](../ansible/roles/vpn/tasks/main.yml)
  keeps rendering templates from
  [`server/templates/`](../server/templates/) via `.j2` — the Jinja2 source
  tree doesn't move.
- Destination paths change from `{{ deploy_path }}/runtime/...` to
  `/etc/nginx/conf.d/` and `/etc/v2ray/`.
- `notify: recreate stack` / `notify: reload nginx` handlers become
  `ansible.builtin.systemd: state=reloaded` equivalents.
- [`ansible/roles/letsencrypt/tasks/main.yml`](../ansible/roles/letsencrypt/tasks/main.yml)
  collapses — see the "LE bootstrap" axis below.
- The `community.docker` Ansible collection dependency goes away.

## Side-by-side comparison

Grouped by axis. Winner noted per axis; sums below.

### Install / upgrade

- **Docker:** pulls `v2ray/official:latest`, `nginx:latest`,
  `certbot/certbot` — versions are decoupled from the Ubuntu release.
  Re-deploys on a fresh Ubuntu 26.04 VM in 2028 get the same behavior as
  today.
- **Bare metal:** `apt install nginx v2ray? certbot`. V2Ray is not in
  the Ubuntu archive, so you're on the upstream install script or pinned
  GitHub releases anyway. Nginx follows the distro's version, which drifts
  across Ubuntu LTS cycles.
- **Winner:** Docker, on reproducibility across distro upgrades. Bare metal
  wins slightly on smaller attack surface (no Docker daemon, no containerd).

### Config churn

- Templates stay in `server/templates/*.tmpl` either way — both paths render
  to *some* on-disk config.
- **Docker:** `notify: recreate stack` via `community.docker.docker_compose_v2`.
- **Bare metal:** `notify: reload nginx` + `notify: restart v2ray` via
  `ansible.builtin.systemd`. Marginally simpler plumbing.
- **Winner:** Tie, with a very slight edge to bare metal on handler
  simplicity.

### Let's Encrypt bootstrap

- **Docker (today):** the two-phase dance documented in `CLAUDE.md` under
  "Let's Encrypt bootstrap" — render `acme-only.conf.j2` first, bring up
  nginx alone, run `certbot --webroot`, re-render the full nginx conf,
  bring up the full stack. Managed across
  [`ansible/roles/vpn/tasks/main.yml`](../ansible/roles/vpn/tasks/main.yml)
  and
  [`ansible/roles/letsencrypt/tasks/main.yml`](../ansible/roles/letsencrypt/tasks/main.yml).
- **Bare metal:** `certbot --nginx` rewrites the nginx config in place and
  reloads nginx, so `acme-only.conf.j2` is deletable and the two-phase
  check-stat-of-fullchain.pem logic disappears.
- **Winner:** Bare metal. This is the one genuinely unambiguous win.

### Log / volume layout

- **Docker:** bind-mounts under `./runtime/logs/{nginx,v2ray}/` and
  `./runtime/certbot/{conf,www}/`. Visible on the host filesystem; no
  logrotate (not currently a problem — volumes are small).
- **Bare metal:** `/var/log/{nginx,v2ray}/` with packaged logrotate rules
  for nginx, and whatever you wire up for V2Ray.
- **Winner:** Tie. Docker's bind-mounts are slightly easier to eyeball;
  bare metal's logrotate story is slightly more polished out-of-the-box.

### Failure isolation + restart

- **Docker:** `restart: unless-stopped` on the compose services, plus the
  container cgroup boundary.
- **Bare metal:** `Restart=on-failure` in each unit file, systemd cgroup.
- **Winner:** Tie. Both recover from `SIGKILL` and both are one `systemctl`
  or `docker` away from stuck-service diagnostics.

### Rootful-Docker-specific pain

- The `cannot expose privileged port 80` class of errors documented in
  `README.md` troubleshooting only happens because of rootful Docker + port
  binding conventions.
- **Bare metal:** nginx binds 80/443 directly as root-via-systemd; no
  analogue.
- **Winner:** Bare metal, minor. In practice this error surfaces once, on
  the first deploy, and is documented.

### Reproducibility on throwaway VMs (`just az-cycle`)

- **Docker:** image digests are stable; a VM minted today and a VM minted
  in six months run identical binaries (modulo `:latest` tag churn, which
  the project could pin if it mattered).
- **Bare metal:** `apt-get install` gives you whatever the Ubuntu archive
  has on that day. For V2Ray specifically, the upstream install script is
  reasonably stable but not digest-pinned.
- **Winner:** Docker. This matters for this project because the Azure loop
  is explicitly throwaway-VM oriented.

### Test harness (`test/`)

- **Docker (today):** [`test/Dockerfile`](../test/Dockerfile) runs an
  Ubuntu 24.04 container with SSH. Per `CLAUDE.md`'s "Local test harness
  scope", it already can't validate systemd or docker-in-docker, but it
  does validate apt/SSH/Jinja2 plumbing in the `common` and `docker` roles.
- **Bare metal:** `systemctl` *is* the plumbing, so the current container
  harness validates even less. A meaningful harness would need VM-level
  isolation — Vagrant, Multipass, Molecule + LXD, or GitHub Actions with a
  service VM. All materially more complex than the current Dockerfile.
- **Winner:** Docker, by a wide margin. This is the second-biggest factor
  after reproducibility.

### Operator muscle memory

- The whole repo — `just logs-v2ray`, `just logs-nginx`, `just ps`,
  [`scripts/verify.sh`](../scripts/verify.sh) — is shaped around
  `docker compose`. Switching to systemd means rewriting all of the above
  and retraining fingers.
- **Winner:** Docker, inertia.

### Tally

Bare metal wins: LE bootstrap (strong), rootful port-80 pain (minor),
attack surface (minor).
Docker wins: reproducibility (strong), test harness (strong), operator
muscle memory (strong).
Ties: config churn, log layout, failure isolation.

The three Docker wins are all tied to the project's actual working mode
(throwaway Azure VMs, single-operator, container-based test harness). The
strong bare-metal win (LE bootstrap) is a one-time complexity cost already
paid, not an ongoing tax.

## Migration cost if we did switch

Rough shape of the diff, for calibration:

- Rewrite [`ansible/roles/vpn/tasks/main.yml`](../ansible/roles/vpn/tasks/main.yml):
  swap template destinations, swap notify handlers, drop the cert-exists
  stat check + ACME-only branch.
- Rewrite [`ansible/roles/letsencrypt/tasks/main.yml`](../ansible/roles/letsencrypt/tasks/main.yml):
  replace the nginx-up → webroot-certbot → render-full-conf block with a
  single `certbot --nginx` invocation.
- Delete [`server/compose.yml`](../server/compose.yml) and the
  `acme-only.conf.j2` template; move both to `legacy/` per the repo's
  "move to legacy, don't delete" policy from `CLAUDE.md`.
- Drop the `community.docker` collection from
  [`ansible/requirements.yml`](../ansible/requirements.yml); the
  [`ansible/roles/docker/`](../ansible/roles/docker/) role becomes
  unnecessary (or stays, gated off).
- Rewrite [`scripts/verify.sh`](../scripts/verify.sh) (still hits the HTTP
  surface, so this is small) and the `just logs-v2ray` / `just logs-nginx`
  / `just ps` recipes (systemd + `journalctl` equivalents).
- Rework [`test/Dockerfile`](../test/Dockerfile) into something
  systemd-capable (switch to `jrei/systemd-ubuntu` or move to Molecule +
  LXD), or accept that the test harness validates strictly less than
  today.
- Update [`CLAUDE.md`](../CLAUDE.md) design-constraints section (remove
  "Rootful Docker" constraint, add "systemd-managed binaries" constraint)
  and [`docs/LEGACY.md`](LEGACY.md).

Total effort is roughly a repeat of the original IaC refactor that produced
the current `pre-iac-refactor` tag. That refactor was worth doing because
the pre-refactor state had real footguns (see `docs/LEGACY.md`). A
Compose → systemd refactor today does not pay off a comparable debt.

## Decision

**Stay on rootful Docker Compose.** The genuine bare-metal wins (simpler LE
bootstrap, no rootful-port pain, smaller attack surface) are real but
one-time, already paid, or minor. The Docker wins (reproducibility on
throwaway VMs, test harness continuity, operator muscle memory) recur every
time the operator touches the project.

Recorded trade-offs:

- The two-phase LE bootstrap in
  [`ansible/roles/letsencrypt/tasks/main.yml`](../ansible/roles/letsencrypt/tasks/main.yml)
  is more code than `certbot --nginx` would need on bare metal. Accepted.
- Running a Docker daemon on the VPS is a larger attack surface than three
  systemd units. Accepted; the VPS is single-operator.
- `:latest` tags in [`server/compose.yml`](../server/compose.yml) are not
  digest-pinned today. This is a *fixable* property of the Docker path, not
  a reason to switch off Docker. Out of scope for this doc.

## Future escape hatch

If the operator ever drops Docker — whether by choice (licensing panic,
disk pressure, cheaper VM SKU) or by necessity — the bare-metal layout
sketched in the first section of this doc is the pre-drawn target. Partial
precedent exists in the archived pre-Docker flow described in
[LEGACY.md](LEGACY.md): pre-refactor, configs already lived under `/etc/`
in a similar shape. The migration would be "re-read this doc, follow the
bullets under 'Migration cost if we did switch', implement."
