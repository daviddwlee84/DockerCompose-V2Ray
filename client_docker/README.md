# Use Docker to host Clash

1. Install docker

```bash
# https://github.com/docker/docker-install
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
```

> NOTE: better setup as [rootless mode](https://docs.docker.com/engine/security/rootless/)

2. Setup docker mirror (rootless mode paths)

`~/.config/docker/daemon.json`

```json
{
    "registry-mirrors": ["https://docker.m.daocloud.io", "https://dockerhub.azk8s.cn", "https://docker.mirrors.ustc.edu.cn", "https://dockerproxy.com", "https://mirror.baidubce.com", "https://docker.nju.edu.cn", "https://mirror.iscas.ac.cn"]
}
```

```bash
systemctl --user daemon-reload
systemctl --user restart docker
```

```bash
docker info
```

```
...

 Registry Mirrors:
  https://docker.m.daocloud.io/
  https://dockerhub.azk8s.cn/
  https://docker.mirrors.ustc.edu.cn/
  https://dockerproxy.com/
  https://mirror.baidubce.com/
  https://docker.nju.edu.cn/
  https://mirror.iscas.ac.cn/

...
```

3. Start Clash

NOTE: you should modify `config.yaml` with proper `proxies` settings

```bash
docker compose up --build

docker compose -f docker-compose-host-network.yaml up --build
```

```
clash-1  | time="2024-11-21T11:56:12Z" level=info msg="Start initial compatible provider Auto Select"
clash-1  | time="2024-11-21T11:56:12Z" level=info msg="Start initial compatible provider PROXY"
clash-1  | time="2024-11-21T11:56:12Z" level=info msg="Start initial compatible provider Final"
clash-1  | time="2024-11-21T11:56:12Z" level=info msg="inbound http://:7890 create success."
clash-1  | time="2024-11-21T11:56:12Z" level=info msg="inbound socks://:7891 create success."
clash-1  | time="2024-11-21T11:56:12Z" level=info msg="RESTful API listening at: 127.0.0.1:9090"
```

> NOTE: `export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7891` this depends on your config, like:
>
> ```yaml
> port: 7890
> socks-port: 7891
> allow-lan: true
> external-controller: 0.0.0.0:9090
> external-ui: ui_pages
> ```
>
> NOTE: if we use docker, we should set "allow-lan: true" otherwise host cannot access.
> As well as external-controller should set to `0.0.0.0:9090`

```bash
# Test with Google
sudo apt install w3m
w3m google.com
```

You can change config and set some routing in the Web UI

http://localhost:9090/ui/
http://localhost:9090/ui/?secret=clash_secret

---

```bash
$ clash -h
Usage of clash:
  -d string
        set configuration directory
  -ext-ctl string
        override external controller address
  -ext-ui string
        override external ui directory
  -f string
        specify configuration file
  -secret string
        override secret for RESTful API
  -t    test configuration and exit
  -v    show current version of clash
```

- [What is Clash? | Clash Knowledge](https://en.clash.wiki/)
- [快速入手 | Clash 知识库](https://clash.wiki/configuration/getting-started.html)

---

- [Downloading and installing Node.js and npm | npm Docs](https://docs.npmjs.com/downloading-and-installing-node-js-and-npm)
- [nvm-sh/nvm: Node Version Manager - POSIX-compliant bash script to manage multiple active node.js versions](https://github.com/nvm-sh/nvm?tab=readme-ov-file#installing-and-updating)
- [How to install Node.js by NVM? Manage multiple versions of Node.js with nvm. | by Masud Afsar | Medium | Geek Culture](https://medium.com/geekculture/how-to-install-node-js-by-nvm-61addf4ab1ba)

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
```

- [Installation | pnpm](https://pnpm.io/installation#on-posix-systems)

```bash
curl -fsSL https://get.pnpm.io/install.sh | sh -

cd hinak0_yacd
pnpm i

pnpm build
# copy ./public to override ../ui_pages

pnpm start
```

---

If curious about what's inside `Country.mmdb`

`pip install -i https://pypi.tuna.tsinghua.edu.cn/simple geoip2`

```python
import geoip2.database

reader = geoip2.database.Reader('Country.mmdb')

# Note: This is just an example and not efficient for large datasets
ip_addresses = ['8.8.8.8', '1.1.1.1', '203.0.113.0']

for ip in ip_addresses:
    try:
        response = reader.country(ip)
        print(f"IP: {ip}, Country: {response.country.iso_code}, Name: {response.country.name}")
    except geoip2.errors.AddressNotFoundError:
        print(f"IP: {ip} not found in the database.")
```

```
IP: 8.8.8.8, Country: US, Name: United States
IP: 1.1.1.1, Country: None, Name: None
IP: 203.0.113.0 not found in the database.
```
