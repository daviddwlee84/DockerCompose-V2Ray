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

**This got more urgent with the 2026-07 REALITY migration.** That host is still
running `v2ray/official:latest` — a container image last pushed six years ago —
with `alterId: 64` (legacy non-AEAD VMess). Both are called out in
[`docs/ProtocolEvaluation.md`](docs/ProtocolEvaluation.md). None of the new work
reaches it until this migration happens; the repo default is now
`vpn_protocol: reality`, but the live box is still on the old stack entirely.

Migration steps (when convenient — no urgency, the box is stable):

1. Create `ansible/inventory/prod.ini` + `ansible/host_vars/<host>/vault.yml`
   (domain / UUID / LE email / REALITY keys). `just az-configure` can regenerate
   the inventory from the Azure throwaway flow, and generates REALITY key material
   automatically; for a hand-built vault use `just reality-keys --format vault-yaml`.
2. Decide the protocol for the cutover. `vpn_protocol: both` keeps the existing
   VMess clients alive on `vmess_ws_port` while you move them — but note their
   `alterId` must become `0` regardless, because Xray-core dropped the legacy
   variant. See [`docs/REALITY-MIGRATION.md`](docs/REALITY-MIGRATION.md).
3. `just deploy` to lay down `/opt/vpn` (compose + runtime configs) fresh.
4. `DOMAIN=… just verify` then `just az-client && just verify-proxy` — the second
   one is what actually proves traffic flows.
5. Retire the old `~/DockerCompose-V2Ray` clone once the `/opt/vpn` stack is
   serving.

**Caveat**: this VPS also runs other unrelated services alongside the
`nginx`/`xray`/`certbot` stack. They're out of scope for this repo; do not disturb
them during the migration (the `vpn` compose stack is independent of them).
**Port 443 changes hands** in `reality`/`both` mode — Xray takes it from nginx.
If any of those unrelated services expects to be served by that nginx on 443,
deal with it before deploying.

## Harden `clients/mihomo-docker` (non-DNS leftovers)

The DNS half of this was fixed alongside
[`pitfalls/browser-cannot-load-google-match-final-bare-ip.md`](pitfalls/browser-cannot-load-google-match-final-bare-ip.md).
These came out of the same audit and are still open:

1. **Unauthenticated control plane, published on every interface.**
   `config.example.yaml` has `external-controller: 0.0.0.0:9091` with `secret`
   commented out, and both compose files publish `9091:9091`. Combined with
   `allow-lan: true` + `bind-address: "*"` + `7890:7890` and no `authentication:`,
   anyone on the LAN gets both an open proxy relay and full API control. This is the
   exact weakness [`docs/clash/API.md`](docs/clash/API.md) already flags. Fix by
   requiring a `secret`, and publishing as `127.0.0.1:9091:9091` / `127.0.0.1:7890:7890`
   unless LAN access is actually wanted.
2. **`cache.db` durability.** Now that `profile.store-fake-ip: true` is set, the
   config dir must be durable. The official image declares `/root/.config/mihomo` a
   `VOLUME` (anonymous volume — survives recreate, dies on `down -v`);
   `docker-compose.binary.yaml` runs bare `alpine:latest` with no volume there at all,
   so `cache.db` dies on any recreate. Mount a named volume in both.
3. **Stale "alpine can't do DoH" claim.** `README.md` and
   `docker-compose.binary.yaml` both say bare alpine lacks `ca-certificates` for DoH
   nameservers. Verified false — `alpine:latest` ships `ca-certificates-bundle`, which
   Go's `crypto/x509` reads directly. Left uncorrected it will talk a future operator
   back into plain UDP:53, which is the whole bug above.
4. **Rule-order nits.** `DOMAIN-KEYWORD,github,PROXY` sits above `GEOIP,CN`; the
   `IP-CIDR6,fd7a:115c:a1e0::/48,DIRECT,no-resolve` rule is dead weight under
   `ipv6: false`.
