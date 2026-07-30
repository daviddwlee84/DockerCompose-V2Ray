# 把 default 協議從 VMess+WS+TLS 換成 VLESS + XTLS-Vision + REALITY

## Context

起因：operator 手上已經有一個跑 VLESS+Reality 的節點（`clients/mihomo-docker/config.example.yaml`
裡的 `Az Sg`），回頭問本 repo 的 server 端「VMess 是不是 outdated、有什麼缺陷、能不能改
default 用 VLESS」。

稽核現況後找到三個**具體**問題（不是一般性的「VMess 比較舊」而已）：

1. **`image: v2ray/official:latest` 這個 Docker Hub repo 最後一次推送在 6 年前**
   （v4.x 時代）。線上跑的是一顆六年沒有任何安全更新的 binary。
   出現在 `server/compose.yml:29` 與 `ansible/roles/vpn/templates/compose.yml.j2:30`。
2. **`alterId: 64` = 舊式 MD5 認證的非 AEAD VMess** —— 正是最容易被主動探測/重放指紋化的
   那一種。全 repo 一致地錯：`config.json.tmpl:17`、`config.json.j2:18`、
   `scripts/vmess_client.py:211`、`README.md:127`、`clients/docker/config.yaml:51,66`。
   repo 自己的 `docs/clash/Core.md` 早已標注它「已淘汰」，但沒人回頭改 server。
3. **靜態特徵疊加**：SNI 是 `*.japaneast.cloudapp.azure.com`（雲端動態 FQDN，本身就是高辨識度
   訊號）＋ 固定 WS path `/v2ray` ＋ 憑證是自己的 LE 憑證。三者都在被動 DPI 的可指紋化清單上。

`docs/ProtocolEvaluation.md` 其實早就把結論寫對了（VLESS+Vision+REALITY 是 2026 首選），但當時
被 `CLAUDE.md` 的「協議遷移不在範圍內」硬約束擋住，只留成研究記錄。這次 operator 明確要求
重開這個決定，所以硬約束要一併改寫。

**目標**：REALITY 成為 default，同時保留一個可選的 legacy VMess/WS 通道，讓 operator 用一個
變數決定要 deploy 哪一套。

## 已定的決策（來自本次問答）

| 決策 | 選擇 |
|---|---|
| 拓樸 | **REALITY + 借用外站 SNI** — Xray 直接聽 443，`dest` 指向真實大站 |
| 過渡 | **雙套並存，用變數選** — 不是同時硬跑兩套，而是 `vpn_protocol` 三選一 |
| 範圍 | **文件 + 實作** |

一個關鍵限制決定了「並存」的形狀：**REALITY 與 nginx-TLS 不能共用 443**。REALITY 必須自己
擁有 443（否則就失去「探測者被透明轉發到真站」這個唯一賣點）。所以「並存」實作成
deploy-time 的三態開關，`both` 模式把 legacy WS 放到另一個 port：

```
vpn_protocol: reality    (default)
  Xray :443  ──REALITY──►  clients (SNI=www.apple.com, flow=xtls-rprx-vision)
                └─非 REALITY 流量 → 透明轉發 www.apple.com:443
  nginx :80  落地頁         certbot/LE 不啟用

vpn_protocol: vmess_ws   (= 今天的行為，一字不差)
  nginx :443 (LE 憑證) ─/v2ray─► Xray VMess/WS inbound
  nginx :80  ACME + 301     certbot 續期

vpn_protocol: both       (過渡期)
  Xray :443  REALITY
  nginx :80  落地頁 + ACME
  nginx :8443 (LE 憑證) ─/v2ray─► Xray VMess/WS inbound   ← 需額外開 NSG/ufw
```

三種模式都由**同一顆 Xray container** 承載（Xray-core 原生同時支援 vless 與 vmess inbound），
順帶解決發現 #1。

## Part 1 — 文件

### 1a. 改寫 `docs/ProtocolEvaluation.md`

保留現有的協議橫向比較、GFW 威脅模型、偵測風險排序（那些都還正確），改掉框架：

- 移除開頭「本專案硬約束…遷移到 Xray / VLESS 明確不在範圍內」那段。
- 新增 **「本專案實機稽核（2026-07）」** 一節，把上面三個發現寫成可查證的條目
  （檔案:行號 + 為什麼危險）。這是這份文件目前最缺的東西 —— 它只講了通論，沒講
  「我們自己這台的具體毛病」。
- 「對本專案的意涵」改寫成**決策記錄**：default 改為 REALITY，理由、代價、什麼情況下
  回頭用 `vmess_ws`。文末的「何時該重新檢視」觸發點反過來變成「什麼時候 REALITY 也會失效」
  （裸 Reality 在俄 TSPU 已失效 → 必須搭 Vision；QUIC 路線作為未來備援）。

### 1b. 新增 `docs/REALITY-MIGRATION.md`

操作型文件（zh-TW，比照現有 docs 風格，含 mermaid 拓樸圖）：

- 三種 `vpn_protocol` 模式的拓樸圖與取捨。
- **金鑰材料**：x25519 keypair 怎麼生、short ID 規則（hex、偶數長度、≤16 字元）、
  存進 vault 的哪些 key。
- **`dest` / `serverNames` 選擇準則**：必須支援 TLS 1.3 + H2、不得 301 到別的網域、
  地理位置要近（延遲直接疊加到每一次握手）、避開自己國家的站。預設 `www.apple.com:443`。
- **必踩的坑**（先寫進文件，實際踩到再進 `pitfalls/`）：
  - Xray-core **完全移除了 `alterId > 0` 的 legacy VMess**。`both` 模式下舊 client
    必須改成 AEAD（`alterId: 0`），否則直接連不上 —— 這是升級 core 的強制副作用。
  - `ghcr.io/xtls/xray-core` 是 distroless（官方文件原話：「No root privileges, no shell
    environment」），`docker compose exec xray sh` 不存在，只能靠 `docker logs`。
  - REALITY 不使用自己的憑證 → 用瀏覽器開 `https://<你的域名>/` 會拿到 dest 站的憑證而
    憑證名稱不符（TLS 錯誤）。這是預期行為，不是壞掉。
  - client 端 `server:` 仍填 FQDN（不是裸 IP），這樣 `just az-rotate-ip` 換 IP 時
    client 設定不用改 —— SNI 是借來的，跟 `server:` 填什麼無關。
- **回退**：把 `vpn_protocol` 設回 `vmess_ws` + `just deploy` 即可（LE 憑證與 certbot
  會自動回來）。
- **正式機注意**：`TODO.md` 記載線上那台仍在 pre-IaC legacy 佈局、`just deploy-fast`
  打不到 → 本次改動先在 throwaway Azure VM 驗證，正式機切換另案。

### 1c. 只改「已經變成錯的那幾行」

不重寫，只修正事實：

`README.md`（開頭一句、client setup 段的 alterId 64、repo layout 表、troubleshooting 的
`/v2ray` 400 說明）、`server/README.md`、`CLAUDE.md`（見 Part 2 開頭）、
`docs/clash/{README,BestPractice,Core,Clients,SelfHostProviders}.md`（多處寫「遷移不在範圍內」
與 `alterId: 64/0`）、`docs/OBSERVABILITY.md:55-60`、`docs/BareMetalEvaluation.md:48`、
`docs/MULTI-HOST.md:33`、`test/README.md:18`、`clients/docker/config.yaml:47-66`、`TODO.md`。

## Part 2 — Server 端實作

### 2a. `CLAUDE.md`

- 「What this project is」：VMess over WebSocket → VLESS + XTLS-Vision + REALITY。
- Design constraints 的 `**V2Ray / VMess.**` 那條整條改寫成新決定，並註明 `vmess_ws`
  仍是受支援的 legacy 模式。
- `**TLS always.**` 需要重新表述：REALITY **是**真 TLS 1.3，只是憑證不是我們的。
- Architecture 加一節說明 `vpn_protocol` 開關與「REALITY 不能與 nginx 共用 443」。

### 2b. 新變數 — `ansible/group_vars/all.yml`

```yaml
vpn_protocol: reality                 # reality | vmess_ws | both
reality_dest: "www.apple.com:443"
reality_server_names: ["www.apple.com"]
reality_client_fingerprint: chrome    # 只寫進 client 設定，server 不用
vmess_ws_port: 8443                   # 只在 vpn_protocol == both 時使用
xray_image: "ghcr.io/xtls/xray-core:<pin>"   # 實作時查當前 release 並釘住
letsencrypt_enabled: "{{ vpn_protocol in ['vmess_ws', 'both'] }}"
```

`firewall_allowed_tcp` 在 `both` 時附加 `vmess_ws_port`。

### 2c. Vault / 別名（沿用既有 `vars.yml` → `vault.yml` indirection）

`vault.yml.example` + `group_vars/vpn/vars.yml` 各加三個：
`vault_reality_private_key` / `vault_reality_public_key` / `vault_reality_short_id`
→ 別名 `reality_private_key` / `reality_public_key` / `reality_short_id`。

**`vault_v2ray_uuid` 這個 key 名稱不改**（VLESS 沿用同一顆 UUID）。理由：磁碟上既有的
`host_vars/<rg>/vault.yml` 是加密的，改 key 名會讓所有現存 host vault 靜默失效。
public key 雖非機密，仍放 vault，好讓 client 產生器不必安裝 xray 就能反推。

### 2d. 模板

沿用 repo 的 `.tmpl`（真相來源）+ `.j2`（實際渲染）雙寫規則：

- `git mv` `server/templates/v2ray/config.json.tmpl` → `server/templates/xray/config.json.tmpl`，
  `ansible/roles/vpn/templates/v2ray/config.json.j2` → `.../xray/config.json.j2`，內容改寫成
  依 `vpn_protocol` 產生 vless-reality inbound / vmess-ws inbound / 兩者。
  REALITY inbound 欄位以官方 `XTLS/Xray-examples` 為準：
  `settings.decryption: "none"`、client 帶 `flow: "xtls-rprx-vision"`、
  `streamSettings.security: "reality"` + `realitySettings.{dest,xver,serverNames,privateKey,shortIds}`。
  VMess inbound **不再寫 `alterId`**（Xray 只支援 AEAD）。
  `monitoring_enabled` 的 stats/api 區塊原樣保留。
- `nginx/v2ray.conf.j2` → `nginx/ws.conf.j2`，`listen` port 依模式在 443 / `vmess_ws_port` 間切換。
- 新增 `nginx/landing.conf.j2`：`reality`/`both` 模式用，port 80 只服務落地頁
  （**不能**再 `return 301 https://` —— 443 已經是 Xray 了），`letsencrypt_enabled` 時
  保留 `/.well-known/acme-challenge/`。
- `compose.yml.j2`：`v2ray` service → `xray`，image 換成 `{{ xray_image }}`，
  volume 改成官方路徑 `./runtime/xray:/usr/local/etc/xray:ro` 與
  `./runtime/logs/xray:/var/log/xray`；443 的 `ports:` 依模式掛在 xray 或 nginx 上；
  certbot service 用 `letsencrypt_enabled` 包起來。`server/compose.yml` 同步。

### 2e. Role 邏輯

- `roles/vpn/tasks/main.yml`：目錄樹 `runtime/v2ray` → `runtime/xray`、
  `runtime/logs/v2ray` → `runtime/logs/xray`；nginx conf 依模式選 `landing` / `ws` /
  `acme-only`（LE bootstrap 期間）。
- `roles/vpn/handlers/main.yml`：`restart v2ray` → `restart xray`。
- `roles/vpn/templates/logrotate-vpn.conf.j2`：改成 `logs/xray/*.log`，**過渡期同時保留舊的
  `logs/v2ray/*.log` glob**，免得既有主機上的舊 log 從此不再輪替。
- `roles/letsencrypt/tasks/main.yml`：把憑證 bootstrap 整個 block 用
  `when: letsencrypt_enabled | bool` 包起來；「Bring up full compose stack」維持無條件執行
  （這個 role 實質上也是唯一會拉起 stack 的地方）。
- `roles/vpn/templates/alloy/config.alloy.j2`：log 路徑 `/var/log/v2ray` → `/var/log/xray`。

## Part 3 — Client 與 laptop 端工具

### 3a. 新增 `scripts/reality_keys.py`

uv inline-script（比照 `az_configure.py` / `vmess_client.py` 的寫法），依賴 `cryptography`：
生 x25519 keypair（base64url 無 padding）＋ 隨機 short ID（8 字元 hex）。

⚠️ **實作時必須交叉驗證編碼**：跑一次
`docker run --rm ghcr.io/xtls/xray-core:<pin> x25519`，確認 Python 產出的格式與 xray 自己
產的一致。腳本提供 `--verify-with-docker` 做這件事。編碼猜錯會是那種「設定看起來完全正常但
就是連不上」的坑。

### 3b. `scripts/az_configure.py`

`write_host_vault()` 一併生成並寫入 reality 三件套；`--force` 時連同 UUID 一起輪換。
既有已加密的 vault 因為沒有這些 key，deploy 時會是 undefined variable —— 加一個明確的
前置檢查與可讀的錯誤訊息（指向 `just vault-edit <rg>` 或 `az-configure --force`）。

### 3c. `git mv scripts/vmess_client.py scripts/client_config.py`

（用 `git mv` 讓 history 跟著走，符合 repo 慣例）

- 依 `vpn_protocol` 產出對應格式：
  - REALITY：`vless.txt`（`vless://<uuid>@<host>:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=<sni>&fp=chrome&pbk=<pub>&sid=<sid>&type=tcp#<remark>`）、
    `clash.yaml`（mihomo `type: vless` + `reality-opts`，形狀對齊
    `clients/mihomo-docker/config.example.yaml:210-224`）、`xray-client.json`、`human.md`、`qr.png`。
  - `vmess_ws` / `both`：另外產 VMess 那組，且 **`alterId` 一律 0**。
- 移除 `DEFAULT_ALTER_ID = 64` 這個常數與它上面那條已經過期的註解。
- `Justfile` 的 `az-client`、`README.md`、`docs/MULTI-HOST.md` 內的路徑同步。

### 3d. `clients/mihomo-docker/config.example.yaml`

`Az Sg` 的欄位改成指向本 repo 產出的節點（placeholder 不變），並補一行註解說明
`servername` 是借來的、與 `server:` 無關。`clients/docker/config.yaml` 的兩個
`alterId: 64` 一併修掉（那是發現 #2 的最後兩處）。

## Part 4 — 驗證

### 4a. `scripts/verify.sh` 改成 mode-aware

`reality` 模式下今天那三項檢查有兩項會失效（443 不再是我們的 nginx、也不再有我們的憑證）。
改成：

| 檢查 | 方法 | 意義 |
|---|---|---|
| 落地頁 | `curl http://$DOMAIN/` → 200 | nginx 還活著 |
| REALITY 前門 | `openssl s_client -servername <serverName> -connect $DOMAIN:443` → `Verify return code: 0` **且** peer 憑證 SAN 命中 dest 站 | 證明「偷憑證 + 透明轉發」真的在動 |
| 沒有洩漏自己的憑證 | 同上但 `-servername $DOMAIN`，斷言拿到的**不是** Let's Encrypt 簽給 `$DOMAIN` 的憑證 | 確認舊的 nginx-TLS 沒有殘留在 443 |

`vmess_ws` 維持原三項；`both` 兩組都跑（WS 那組打 `vmess_ws_port`）。

### 4b. 新增 `just verify-proxy` — 唯一的端到端證明

上面全部都只證明「握手看起來對」，證明不了「流量真的通」。加一個 target：用
`ghcr.io/xtls/xray-core` 起一顆**本機 throwaway client** 吃 `out/client/xray-client.json`，
開一個 SOCKS port，然後
`curl -x socks5h://127.0.0.1:<port> -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204`
斷言 204。

### 4c. 完整驗收流程

```bash
just test-up && just test-ping          # 模板渲染 / inventory 沒壞（容器內無 dockerd，只驗這些）
AZ_YES=1 just az-up && just az-configure
just deploy
just verify                             # REALITY 模式的新檢查
just az-client && just verify-proxy     # 端到端：真的能出去
# 然後把 vpn_protocol 改成 vmess_ws / both 各 deploy 一次，確認兩條路都還在
just az-down -y
```

## 風險與回退

- **正式機不在這次範圍**：線上那台仍是 pre-IaC 佈局（`TODO.md`），`just deploy-fast`
  打不到。全部驗證都在 throwaway VM 上做，正式機切換另案處理。
- **`v2ray-exporter` 對 Xray 的相容性未驗證**。Xray 有等價的 StatsService gRPC API，
  理論上可用，但 `wi1dcard/v2ray-exporter` 的 README 只寫 V2Ray/V2Fly。
  `monitoring_enabled` 預設 false，所以不擋主線；實作時實測，不通就換
  `compassvpn/xray-exporter`（明確宣稱支援 Xray）。
- **`dest` 站的可用性變成我們的依賴**：Apple 若改架構或封了我們的 VPS IP，握手會壞。
  文件裡列 2–3 個備選並說明怎麼換。
- **回退路徑很便宜**：`vpn_protocol: vmess_ws` + `just deploy`。這正是把它做成開關
  而不是一刀砍掉的原因。

## 主要改動檔案

```
新增   docs/REALITY-MIGRATION.md
新增   scripts/reality_keys.py
新增   ansible/roles/vpn/templates/nginx/landing.conf.j2
改寫   docs/ProtocolEvaluation.md          CLAUDE.md
git mv server/templates/v2ray/            → server/templates/xray/
       ansible/roles/vpn/templates/v2ray/ → .../xray/
       ansible/roles/vpn/templates/nginx/v2ray.conf.j2 → nginx/ws.conf.j2
       scripts/vmess_client.py            → scripts/client_config.py
修改   ansible/group_vars/all.yml          ansible/group_vars/vpn/{vars.yml,vault.yml.example}
       ansible/roles/vpn/{tasks,handlers}/main.yml
       ansible/roles/vpn/templates/{compose.yml.j2,logrotate-vpn.conf.j2,alloy/config.alloy.j2}
       ansible/roles/letsencrypt/tasks/main.yml
       server/compose.yml                  scripts/{az_configure.py,verify.sh}
       Justfile                            README.md  server/README.md  TODO.md
       clients/docker/config.yaml          clients/mihomo-docker/config.example.yaml
       docs/{OBSERVABILITY,BareMetalEvaluation,MULTI-HOST}.md
       docs/clash/{README,BestPractice,Core,Clients,SelfHostProviders}.md
       test/README.md
```
