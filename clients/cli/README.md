# Linux client setup

> **Read this first.** Everything below the "Legacy" heading describes
> **Clash for Windows** + the frozen `Kuingsmile/clash-core` v1.18. Both are
> archived, and **neither can terminate VLESS + REALITY**, which is what this
> repo's server now speaks by default (see
> [`docs/REALITY-MIGRATION.md`](../../docs/REALITY-MIGRATION.md)). They are kept
> for the `vpn_protocol: vmess_ws` legacy mode and for historical reference.

## Recommended (2026)

Two open-source pieces, split by role — the core sees all your traffic, so keep
it open source and keep the shell separate from it. Rationale and the wider
client landscape: [`docs/clash/Clients.md`](../../docs/clash/Clients.md) and
[`docs/clash/BestPractice.md`](../../docs/clash/BestPractice.md).

| Role | Pick | Why |
|---|---|---|
| Core | [**mihomo**](https://github.com/MetaCubeX/mihomo) | The de-facto standard; the only one of the Clash-family cores here that supports VLESS / XTLS-Vision / REALITY |
| Desktop GUI | [**Clash Verge Rev**](https://github.com/clash-verge-rev/clash-verge-rev) | GPL-3.0, Tauri, embeds mihomo and can switch cores from the UI. Windows x64/x86, Linux x64/arm64, macOS 11+ — actively maintained (v2.5.2, 2026-07) |
| Headless / server | mihomo + [`clashtui`](https://github.com/JohanChane/clashtui) | Profile switching and subscription updates without a desktop |
| Containerised | [`../mihomo-docker`](../mihomo-docker) | This repo's own mihomo compose setup |

### Clash Verge Rev

The full desktop runbook now lives in
[`../clash-verge/README.md`](../clash-verge/README.md): official package install,
`just az-client` import, traffic verification, System Proxy vs TUN, conflicts
with a second mihomo service, and Linux duplicate launcher IDs. Verge Rev
embeds mihomo, so there is no separate core to install.

### Headless Linux (no desktop)

Use mihomo directly. The compose setup in [`../mihomo-docker`](../mihomo-docker)
is the maintained path in this repo — it already carries the DNS configuration
that a CN-side client needs (see
[`pitfalls/browser-cannot-load-google-match-final-bare-ip.md`](../../pitfalls/browser-cannot-load-google-match-final-bare-ip.md)),
which is easy to get subtly wrong from scratch.

For a bare binary + systemd instead, take a release from
[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo/releases) and point it at
the same `config.yaml`. [`clashtui`](https://github.com/JohanChane/clashtui) or
[ShellCrash](https://github.com/juewuy/ShellCrash) will manage profiles and the
service unit for you.

---

## Legacy: Clash for Windows + `Kuingsmile/clash-core`

Kept for reference and for the `vpn_protocol: vmess_ws` mode. **Clash for
Windows is archived and closed-source** — see the trust discussion in
[`docs/clash/Clients.md`](../../docs/clash/Clients.md#非開源-client-的信任問題與替代選項).
`Kuingsmile/clash-core` is a frozen v1.18 mirror of the original Dreamacro
core: no REALITY, no VLESS.

- [Clash for Windows](https://www.clashforwindows.net/) (archived)
  - [配置文件 | 使用说明](https://docs.gtk.pw/contents/configfile.html#%E6%A0%BC%E5%BC%8F) — still a decent reference for the *classic* config-file format, which mihomo remains backward-compatible with
- [**Releases · Kuingsmile/clash-core**](https://github.com/Kuingsmile/clash-core/releases)
- [在 Linux 通过 cli 使用 Clash](https://docs.gtk.pw/contents/linux/clash-cli.html#%E5%AE%89%E8%A3%85-installation) => setup `systemctl` service if needed
- [本地安装ShellCrash的教程 | Juewuy's Blog](https://juewuy.github.io/bdaz/)

```bash
wget https://github.com/Kuingsmile/clash-core/releases/download/1.18/clash-linux-386-v1.18.0.gz
gunzip clash-linux-386-v1.18.0.gz
chmod +x clash-linux-386-v1.18.0
sudo mv clash-linux-386-v1.18.0 /usr/local/bin/clash
```

```bash
$ clash
INFO[0000] Start initial compatible provider HKMTMedia
INFO[0000] Start initial compatible provider GlobalMedia
INFO[0000] Start initial compatible provider Auto Select
INFO[0000] Start initial compatible provider PROXY
INFO[0000] Start initial compatible provider Apple
INFO[0000] Start initial compatible provider Final
INFO[0000] inbound http://127.0.0.1:7890 create success.
INFO[0000] inbound socks://127.0.0.1:7891 create success.
INFO[0000] RESTful API listening at: 127.0.0.1:9090
INFO[0249] [TCP] 127.0.0.1:42262 --> github.com:443 match DomainKeyword(github) using PROXY[xxx Server]
INFO[0254] [TCP] 127.0.0.1:42274 --> github.com:443 match DomainKeyword(github) using PROXY[yyy Server]
INFO[0790] [TCP] 127.0.0.1:52190 --> dc.services.visualstudio.com:443 match DomainSuffix(visualstudio.com) using DIRECT
```

## Dashboard (for CLI)

Verge Rev has this built in. For a bare mihomo, point a dashboard at the
external controller (set a `secret` first — see
[`docs/clash/API.md`](../../docs/clash/API.md)):

- [metacubexd](https://github.com/MetaCubeX/metacubexd) / [zashboard](https://github.com/Zephyruso/zashboard) — current, mihomo-aware
- [haishanh/yacd](https://github.com/haishanh/yacd?tab=readme-ov-file) — what [`../docker/`](../docker/) bundles; older

## Todo

Ubuntu

- [ ] Make mihomo a system service (`systemctl`)
- [ ] Update environment variable in shell configure

---

## Others

- [GTK PW](https://v2.gtk.pw/#/register?code=z3sgxglj)

### ShellCrash (ShellClash) => Interactive setup tool

- [echvoyager/shellclash_docker: 在任意Linux主机上, 利用Docker自动创建并配置虚拟OpenWrt路由容器以运行 juewuy's ShellClash 实现旁路由透明代理](https://github.com/echvoyager/shellclash_docker)
- [juewuy/ShellCrash: Run sing-box/mihomo as client in shell](https://github.com/juewuy/ShellCrash)
  - [ShellCrash/README_CN.md at dev · juewuy/ShellCrash](https://github.com/juewuy/ShellCrash/blob/dev/README_CN.md)
  - `export url='https://fastly.jsdelivr.net/gh/juewuy/ShellCrash@master' && wget -q --no-check-certificate -O /tmp/install.sh $url/install.sh  && sudo bash /tmp/install.sh && source /etc/profile &> /dev/null`
  - `/usr/share/ShellCrash/yamls/proxies.yaml`
- [liyaoxuan/ShellClash: One-click deployment and management of Clash services using Shell scripts in Linux environment](https://github.com/liyaoxuan/ShellClash)

### Clash-RS

- [Watfaq/clash-rs: custom protocol network proxy](https://github.com/Watfaq/clash-rs)
- [Welcome to ClashRS User Manual | ClashRS User Manual](https://watfaq.gitbook.io/clashrs-user-manual)
