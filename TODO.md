# TODO

Informal backlog for this single-operator V2Ray server repo. Long-form context
goes in `docs/`; recurring traps go in `pitfalls/`.

## Migrate the live Azure-JP host off the legacy layout onto the IaC flow

The production box is still running the **pre-IaC legacy layout**: a git clone in
`~/DockerCompose-V2Ray/` (on the old `master` state), with the `nginx` container
mounting a *static* `data/nginx/conf.d/v2ray.conf` — NOT the Ansible `/opt/vpn`
flow this repo now targets. See `docs/LEGACY.md` for the old flow.

Consequence: **`just deploy-fast` does not reach this host** (no `prod.ini` /
host_vars vault wired up for it), so any template change has to be hand-applied on
the VPS. This already bit the 2026-07 nginx `proxy_read_timeout` fix — see
[`pitfalls/long-connections-drop-at-60s-other-side-closed.md`](pitfalls/long-connections-drop-at-60s-other-side-closed.md).

Migration steps (when convenient — no urgency, the box is stable):

1. Create `ansible/inventory/prod.ini` + `ansible/host_vars/<host>/vault.yml`
   (domain / UUID / LE email) for this host. `just az-configure` can regenerate
   the inventory from the Azure throwaway flow.
2. `just deploy` to lay down `/opt/vpn` (compose + runtime configs) fresh.
3. `DOMAIN=… just verify` — 200 on `/`, 400 on the WS path, valid TLS chain.
4. Retire the old `~/DockerCompose-V2Ray` clone once the `/opt/vpn` stack is
   serving.

**Caveat**: this VPS also runs other unrelated services alongside the
`nginx`/`v2ray`/`certbot` stack. They're out of scope for this repo; do not disturb
them during the migration (the `vpn` compose stack is independent of them).
