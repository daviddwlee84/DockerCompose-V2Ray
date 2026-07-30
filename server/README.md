# server/

Everything that runs on the VPS.

## Layout

- `compose.yml` — Docker Compose definition in its **default** shape (`vpn_protocol: reality`): nginx on port 80 + Xray-core owning 443. The Ansible-rendered version also covers the `vmess_ws` / `both` modes, where nginx takes 443 back and certbot returns. Paths inside refer to `./runtime/` and `./static/` relative to this directory.
- `templates/` — **truth source** for configs with placeholders.
  - `nginx/landing.conf.tmpl` — port-80 landing page (default mode).
  - `nginx/ws.conf.tmpl` — legacy TLS + WebSocket listener, only used by `vmess_ws` / `both`.
  - `xray/config.json.tmpl` — Xray config with `${V2RAY_UUID}`, `${REALITY_DEST}`, `${REALITY_SERVER_NAME}`, `${REALITY_PRIVATE_KEY}`, `${REALITY_SHORT_ID}` placeholders.
- `static/` — static assets shipped as-is (no templating).
  - `nginx/html/v2ray/index.html` — landing page served at `/`.
- `runtime/` — **generated at deploy time**, gitignored.
  - `nginx/conf.d/` — rendered nginx config(s) for the selected mode.
  - `xray/` — rendered Xray config (chowned to uid 65532, the container's user).
  - `certbot/` — Let's Encrypt certs + ACME challenge workdir (unused in `reality` mode).
  - `logs/` — nginx and xray logs.

## How it's used

The `vpn` role renders the Jinja2 mirrors of these templates (in
`ansible/roles/vpn/templates/`) into `/opt/vpn/runtime/**` on the VPS using values from the
Ansible vault; the `letsencrypt` role then runs `docker compose up`.

The `.tmpl` files here are the human-facing truth source and are **not** what Ansible reads —
when a config gains a parameter, update both. See `CLAUDE.md` "Template / runtime split".
