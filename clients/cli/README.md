## Best Practice (I found)

In GUI, you can use "Clash for Windows" in Windows, MacOS, and Linux. They can share same config YAML.

- [Clash for Windows](https://www.clashforwindows.net/)
  - [Clash for Windows Download – Clash for Windows](https://www.clashforwindows.net/clash-for-windows-download/)
  - [配置文件 | Clash for Windows 代理工具使用说明](https://docs.gtk.pw/contents/configfile.html#%E6%A0%BC%E5%BC%8F)

In CLI, you can use Clash-Core

- [**Releases · Kuingsmile/clash-core**](https://github.com/Kuingsmile/clash-core/releases)
- [在 Linux 通过 cli 使用 Clash | Clash for Windows 代理工具使用说明](https://docs.gtk.pw/contents/linux/clash-cli.html#%E5%AE%89%E8%A3%85-installation) => setup `systemctl` service if needed
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

TODO:

- [haishanh/yacd: Yet Another Clash Dashboard](https://github.com/haishanh/yacd?tab=readme-ov-file)
- [haishanh/yacd - Docker Image | Docker Hub](https://hub.docker.com/r/haishanh/yacd)

## Todo

Ubuntu

- [ ] Make clash a system service (`systemctl`)
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
