# Long-lived proxied connections drop at ~60s with "other side closed" / HTTP 500

**Symptom** (observed on the *client* side, e.g. a Claude Code Copilot proxy whose
traffic is tunneled through this VPN):

```
--> POST /v1/messages?beta=true 500 61s          # ALWAYS 60-62s; short requests (<30s) are fine
ERROR  Error occurred: fetch failed
  [cause]: other side closed
      at TLSSocket.onHttpSocketEnd (node:internal/deps/undici/undici:...)
TypeError: terminated
  [cause]: SocketError: other side closed { code: 'UND_ERR_SOCKET', ... }
```

The end-user app shows an intermittent, retrying error such as
`✻ 500 fetch failed · Retrying in 0s · attempt 3/10`. It only bites **long**
requests — anything whose upstream goes quiet for more than ~60s (an LLM streaming
response that pauses while the model "thinks", a slow first byte, a mostly-idle
SSH-over-proxy session). Short/chatty connections never fail.

## Environment

VMess-over-WebSocket, nginx reverse-proxies TLS → `v2ray` container. The client
reaches the server through a WebSocket tunnel (`location ${V2RAY_WS_PATH}` →
`proxy_pass http://v2ray:...`). One long-lived client TCP connection maps to one
long-lived WS connection through nginx.

## How it was diagnosed (2026-07-03)

- **The tell: every failure clustered at 60-62s**, every success ≤30s. A hard,
  round-number cap on *duration* (not a random reset) points at a configured
  timeout, not flaky upstream or network loss.
- Traced the path: client → Clash (TUN, rule `DOMAIN-KEYWORD,github → PROXY`) →
  this V2Ray node → GitHub Copilot. The 500 is emitted by the client-side proxy
  when *its* upstream socket is closed mid-response.
- Inspected the live nginx conf and found the WebSocket `location` block had **no
  `proxy_read_timeout`**:

  ```nginx
  location /v2ray {
      proxy_pass http://v2ray:30909;
      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection "upgrade";
      # <-- no proxy_read_timeout / proxy_send_timeout
  }
  ```

## Root cause

**nginx's default `proxy_read_timeout` is 60s.** It is the max gap between two
successive reads *from the upstream* — it resets on each read, it is NOT a total
cap. A WebSocket tunnel is long-lived, so whenever the tunneled connection has no
upstream bytes for 60s (LLM thinking pause, idle interactive session), nginx
closes the WS → the client sees `other side closed` at ~60s. WebSocket proxying
*requires* raising this; the default is meant for short request/response HTTP.

## Fix

Add generous timeouts to the WS `location` block. Both the truth-source template
and the Ansible template must change (they're kept in lockstep — see CLAUDE.md
"Template / runtime split"):

- `server/templates/nginx/v2ray.conf.tmpl`
- `ansible/roles/vpn/templates/nginx/v2ray.conf.j2`

```nginx
        proxy_set_header Host $http_host;

        # Keep long-lived / idle WebSocket tunnels alive. nginx's default
        # proxy_read_timeout is 60s → severs any tunnel idle >60s upstream
        # (LLM streaming pause, idle SSH-over-proxy) → "other side closed".
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
```

Deploy: `just deploy-fast` (the `vpn` role renders the conf and its handler runs
`nginx -s reload` in the container). `nginx -s reload` only affects **new**
connections; existing ones keep the old 60s until they reconnect.

## Gotcha: legacy-layout hosts are NOT reached by `just deploy-fast`

The Azure JP box was still running the **pre-IaC legacy layout** — a git clone at
`~/DockerCompose-V2Ray/` (old `master` state), nginx mounting a *static*
`data/nginx/conf.d/v2ray.conf` (dated 2023, no template regeneration) — NOT the
new Ansible `/opt/vpn` flow. Symptoms that you're on a legacy host: `prod.ini`,
`~/.vault-pass`, and `ansible/group_vars/vpn/vault.yml` are absent locally, and
`sudo find /opt/vpn -name v2ray.conf` on the VPS returns nothing.

On such a host, patch in place (back up first):

```sh
CONF=$HOME/DockerCompose-V2Ray/data/nginx/conf.d/v2ray.conf
cp -av "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"        # ALWAYS back up first
# ...insert the two proxy_*_timeout lines into the /v2ray location block...
sudo docker exec nginx nginx -t && sudo docker exec nginx nginx -s reload
# on failure: cp -av "$CONF".bak-* "$CONF"  (restore)
```

Locate the live conf reliably via the container, not a guessed path:
`sudo docker inspect nginx --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'`
and dump the effective config with `sudo docker exec nginx nginx -T`.

**Follow-up**: this host should be migrated onto the IaC flow (`just deploy`) so
the committed template fix actually governs it; until then the in-place edit is a
manual stopgap that a future legacy rebuild could revert (the backup + this doc
are the safety net).

## Verify

```sh
sudo docker exec nginx nginx -T | grep proxy_read_timeout   # → 3600s present
```
Then run a request that takes >60s end-to-end; it should complete (`200`) instead
of dying at `500 61s`.

## References

- nginx `proxy_read_timeout` (default 60s): <https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_read_timeout>
- WebSocket proxying guide: <https://nginx.org/en/docs/http/websocket.html>
