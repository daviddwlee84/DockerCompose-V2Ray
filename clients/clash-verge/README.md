# Clash Verge Rev desktop client

Operational setup for the recommended desktop shell in this repo. Clash Verge
Rev embeds the **mihomo** core, so it can connect to the default
VLESS + XTLS-Vision + REALITY server without installing a second core.

Use only the [official project](https://github.com/clash-verge-rev/clash-verge-rev)
and its [GitHub Releases](https://github.com/clash-verge-rev/clash-verge-rev/releases).
Do not use the archived Clash for Windows package, third-party mirrors, or the
legacy `Kuingsmile/clash-core` v1.18 under [`../docker/`](../docker/): none of
those is the maintained REALITY-capable desktop path.

## Responsibility boundary

| Owner | Responsibility |
|---|---|
| This repo | Generate the node credentials/config, explain Verge installation and import, and verify the tunnel. |
| Clash Verge Rev | Own its runtime profiles, selected proxy, system-proxy/TUN state, bundled mihomo core, and app updates. |
| The dotfiles repo | On Ubuntu, repair desktop integration only: keep the package-owned launcher, remove stale duplicate launchers, and preserve the hidden URL handler. It does not own Verge profiles or secrets. |

This split is deliberate. Proxy credentials belong with the VPN project and
its encrypted vault; generic dotfiles must never contain a UUID, REALITY public
key/short ID, subscription URL, or exported profile.

## 1. Generate this repo's client material

Run this on the operator machine that can unlock the Ansible vault:

```bash
just az-client                    # one tracked VM
just az-client <resource-group>   # required when several VMs are tracked
just verify-proxy <resource-group>
```

The generated files live under `out/client/` (or
`out/client/<resource-group>/`) and are gitignored:

| File | Use |
|---|---|
| `vless.txt` | Single `vless://` link for URI-capable clients or Verge's per-proxy editor; not its subscription URL field. |
| `qr.png` | The same link as a QR code. |
| `clash.yaml` | A mihomo **`proxies:` fragment**, not a complete standalone profile. |
| `clash-verge.yaml` | Complete minimal local Verge profile with the generated nodes, a `PROXY` selector, and `MATCH,PROXY`. |
| `xray-client.json` | Full Xray test client used by `just verify-proxy`. |
| `human.md` | Field table for diagnosis; contains credentials. |

Run `just verify-proxy` before debugging the GUI. If that test fails, the
problem is the server, network, or credentials rather than Clash Verge.

## 2. Install Clash Verge Rev

The upstream release page is the version authority. Pick the stable package
matching the OS and architecture. On Debian/Ubuntu, `dpkg --print-architecture`
maps directly to the release's `amd64`, `arm64`, or `armhf` suffix.

```bash
dpkg --print-architecture

# After downloading the matching official package:
sudo apt install ./Clash.Verge_<version>_<architecture>.deb
```

Using `apt install ./…` is preferable to bare `dpkg -i`: it resolves package
dependencies in the same transaction. Upgrade by installing the newer official
package over the existing one.

Verify the installed package and its launcher provenance:

```bash
dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' clash-verge
dpkg -S /usr/share/applications/'Clash Verge.desktop'
dpkg -L clash-verge | rg '/(bin|applications)/|\.desktop$'
```

On the Ubuntu machine documented here, the expected package name is
`clash-verge`, the executable is `/usr/bin/clash-verge`, and the canonical
visible launcher is `/usr/share/applications/Clash Verge.desktop`. Treat those
as discoverable facts, not files to copy into `~/.local/share/applications`.

## 3. Import and activate the node

The least error-prone route is:

1. Open Clash Verge Rev's **Profiles** page.
2. Drag the generated `clash-verge.yaml` onto that page. Current upstream
   accepts dropped `.yaml`/`.yml` files as local profiles.
3. Activate the imported profile and select the generated node in its `PROXY`
   group.
4. Enable **System Proxy** for applications that honor the desktop proxy, or
   **TUN Mode** when transparent routing is required. TUN may ask Verge to
   install/enable its privileged service; let the app manage that service.

The URL field at the top of the current Profiles page accepts only `http://` or
`https://` subscription URLs; pasting `vless://` there produces **Invalid
profile URL**. The URI is still useful in clients with URI import, and Verge's
**Edit Proxies** dialog accepts one or more proxy URIs, but the generated full
YAML is less error-prone because it also wires the group and catch-all rule.

Do not import the older `clash.yaml` output as if it were a full profile. The
generator deliberately keeps that file in this fragment shape:

```yaml
proxies:
  - name: your-node
    type: vless
    # ... generated REALITY fields ...
```

It is intended to be merged into an existing mihomo profile that also defines
`proxy-groups`, `rules`, DNS, and inbound ports. Use that fragment when
maintaining a versioned base profile; use `clash-verge.yaml` for the direct
desktop setup.

## 4. Verify the running desktop client

Ports are runtime settings, not protocol constants. The current Verge default
on this machine is mixed proxy `7897` and controller `9097`, while the separate
headless mihomo setup under `~/.config/mihomo` uses `7890`/`9090`. Inspect the
live generated config rather than assuming either set:

```bash
VERGE_DATA="$HOME/.local/share/io.github.clash-verge-rev.clash-verge-rev"
rg -n '^(mixed-port|port|socks-port|external-controller|allow-lan|mode):' \
  "$VERGE_DATA/config.yaml"

pgrep -af 'clash-verge|verge-mihomo'
ss -ltnp | rg ':(7897|9097)\b'

# Substitute the discovered mixed-port when it differs.
curl -fsS -x http://127.0.0.1:7897 https://api.ipify.org; echo
curl -fsS https://api.ipify.org; echo
```

The proxied address should be the VPN egress; the direct address should be the
local ISP egress. A listening port proves only that the core started. The curl
comparison proves traffic actually uses the selected node.

### Avoid running two client cores by accident

Clash Verge Rev and the repo's headless mihomo client are independent. Running
both is valid only when intentional; otherwise it becomes unclear which port
the shell, browser, or system proxy is using.

```bash
systemctl --user --type=service | rg -i 'mihomo|clash|verge'
pgrep -af 'mihomo|clash-verge'
env | rg -i '^(http|https|all)_proxy='
gsettings get org.gnome.system.proxy mode
```

Pick one owner for desktop traffic. On a GUI workstation that should normally
be Clash Verge Rev; keep [`../mihomo-docker/`](../mihomo-docker/) or a user
mihomo service for headless/server use.

## Linux launcher identity and duplicate icons

GNOME identifies applications by **desktop file ID** (the `.desktop`
basename), not by the displayed `Name=`. That makes these cases different:

| Files | Result |
|---|---|
| User and system copies both named `Clash Verge.desktop` | Same desktop ID; the user copy shadows the package copy. |
| `Clash Verge.desktop` plus `clash-verge.desktop` | Different desktop IDs; normally two visible icons even if both say `Name=Clash Verge`. |
| `clash-verge-handler.desktop` with `NoDisplay=true` | Hidden URL protocol handler; not a launcher duplicate and should remain. |

Inventory all candidates before removing anything:

```bash
find ~/.local/share/applications /usr/share/applications \
  -maxdepth 1 -type f -iname '*clash*desktop' -print 2>/dev/null

rg -n '^(Name|Exec|TryExec|Icon|NoDisplay|Hidden|StartupWMClass)=' \
  ~/.local/share/applications/*[Cc]lash*.desktop \
  /usr/share/applications/*[Cc]lash*.desktop 2>/dev/null

desktop-file-validate /usr/share/applications/'Clash Verge.desktop'
gsettings get org.gnome.shell favorite-apps
```

For a package-managed Linux install, the safe steady state is one visible
package launcher plus the hidden handler. Remove only the known stale visible
user entries, then refresh the user database:

```bash
rm -f \
  "$HOME/.local/share/applications/Clash Verge.desktop" \
  "$HOME/.local/share/applications/clash-verge.desktop"
update-desktop-database "$HOME/.local/share/applications"
```

The dotfiles `gui_apps_linux` role performs this cleanup idempotently whenever
the package-owned launcher exists. It intentionally does not remove
`clash-verge-handler.desktop` or an old manual binary under `~/.local/opt`;
those are separate cleanup decisions after confirming nothing references them.

## Troubleshooting order

1. **Server/tunnel:** run `just verify-proxy`. Fix the server or credentials if
   this fails.
2. **Core compatibility:** confirm Verge is using bundled mihomo. The archived
   original Clash core cannot speak VLESS + Vision + REALITY.
3. **Profile:** confirm the imported profile is active and the expected node is
   selected, not merely present.
4. **Traffic owner:** check System Proxy/TUN state and make sure another mihomo
   service is not receiving the traffic on a different port.
5. **Process/port:** inspect `pgrep`, `ss`, and the live `mixed-port` above.
6. **Launcher:** compare desktop IDs and `Exec=` targets. An old entry pointing
   to `~/.local/bin/clash-verge-launch` or `~/.local/opt/...` is a manual-install
   leftover, not the package launcher.

Never commit generated files from `out/client/`, real Verge profiles,
subscription URLs, UUIDs, REALITY keys, controller secrets, or exported
WebDAV backups.

## Related documentation

- [`../cli/README.md`](../cli/README.md) — headless/Linux alternatives and the
  archived original-Clash flow.
- [`../mihomo-docker/README.md`](../mihomo-docker/README.md) — maintained
  containerized mihomo client.
- [`../../docs/clash/BestPractice.md`](../../docs/clash/BestPractice.md) — client
  architecture and recommended combination.
- [`../../docs/clash/ConfigManagement.md`](../../docs/clash/ConfigManagement.md)
  — base profiles, providers, Merge/Script enhancements, and hot reload.
- [`../../docs/clash/API.md`](../../docs/clash/API.md) — controller API security
  and diagnostics.
