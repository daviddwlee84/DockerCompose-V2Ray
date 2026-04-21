# server/

Everything that runs on the VPS.

## Layout

- `compose.yml` — Docker Compose definition: Nginx reverse proxy + Certbot (Let's Encrypt auto-renewal) + V2Ray (VMess over WebSocket). Paths inside refer to `./runtime/` and `./static/` relative to this directory.
- `templates/` — **truth source** for configs with placeholders.
  - `nginx/v2ray.conf.tmpl` — nginx server block with `${DOMAIN}` and `${V2RAY_WS_PATH}` placeholders.
  - `v2ray/config.json.tmpl` — V2Ray config with `${V2RAY_UUID}` and `${V2RAY_WS_PATH}` placeholders.
- `static/` — static assets shipped as-is (no templating).
  - `nginx/html/v2ray/index.html` — landing page served at `/`.
- `runtime/` — **generated at deploy time**, gitignored.
  - `nginx/conf.d/` — rendered nginx config.
  - `v2ray/` — rendered V2Ray config.
  - `certbot/` — Let's Encrypt certs + ACME challenge workdir.
  - `logs/` — nginx and v2ray logs.

## How it's used

After the Ansible refactor lands (PR 2), the `vpn` role will:

1. Render `templates/*.tmpl` → `runtime/**` using values from Ansible vault.
2. `docker compose -f compose.yml up -d` on the VPS.

Until PR 2 lands, this directory is **not** wired up to a deploy command — see the pre-IaC flow at the `pre-iac-refactor` git tag or under `legacy/` for the currently-working manual deploy.
