# 自架 Provider：節點與規則 URL 化（Clash + Shadowrocket）

[ConfigManagement.md](ConfigManagement.md) 講了「用 URL 管理節點/規則」的語法，
這章回答**「究竟如何 self-host provider」**——也就是把那些 URL **放在你自己控制的地方**，
讓 Clash（`proxy-providers` / `rule-providers`）與 Shadowrocket（遠端 config / `RULE-SET`）
都能拉取並自動更新。對應 [issue #7 Rules](https://github.com/daviddwlee84/DockerCompose-V2Ray/issues/7)。

## 先分清楚：你要 host 的是兩種東西

| 類型 | 內容 | 機敏性 | Clash | Shadowrocket |
|---|---|---|---|---|
| **節點清單 / 訂閱** | 你的 server、UUID、path… | **高（=帳密）** | `proxy-providers` | `Subscribe` / 遠端 config 的 `[Proxy]` |
| **規則集 (rule-set)** | 域名/IP/分流規則 | 低（多為公開） | `rule-providers` | `RULE-SET` / `DOMAIN-SET` |

**核心原則：規則可公開，節點清單必須保護。** 別把含 UUID 的訂閱丟到公開 repo。

```mermaid
flowchart LR
  src["單一真相來源<br/>(你的 repo / 產生器)"]
  src -->|公開規則| cdn["CDN / 靜態主機<br/>(jsDelivr / nginx / Pages)"]
  src -->|私密節點| auth["受保護來源<br/>(token 路徑 / 私有 repo / nginx basic-auth)"]
  cdn --> clash["Clash (mihomo)"]
  cdn --> sr["Shadowrocket"]
  auth --> clash
  auth --> sr
```

## Host 在哪裡？選項比較

| 方式 | 適合 | 自動更新 | GFW 可達性 | 機敏內容 |
|---|---|---|---|---|
| **自家 nginx 靜態目錄**（本專案已有 nginx） | 規則 + 節點 | 看 client `interval` | 看 VPS IP 是否被封 | 可加 basic-auth / 隱秘路徑 |
| **GitHub repo + raw / [jsDelivr](https://www.jsdelivr.com/) CDN** | 公開規則 | client `interval` | jsDelivr 較穩 | **勿放節點** |
| **GitHub Pages / Gist** | 公開規則 | client `interval` | 中 | 勿放節點 |
| **物件儲存（Cloudflare R2 / S3）+ CDN** | 兩者皆可 | client `interval` | R2/Cloudflare 佳 | 用簽名 URL / token |
| **自架 [subconverter](https://github.com/tindy2013/subconverter)** | 一份訂閱→多格式 | 即時轉換 | 看部署位置 | 後端持有節點，注意保護 |

> 對抗 GFW 的小訣竅：規則用 **jsDelivr / Cloudflare** 這類大 CDN 比直接連 `raw.githubusercontent.com`
> 穩；節點清單則放在你能控管存取的地方（受保護路徑 / 私有來源）。

## A. 通用 Clash（mihomo）

把節點與規則都指向你自架的 URL，base 設定只留骨架：

```yaml
# 自架 provider 版 base config（節選）
proxy-providers:
  my-nodes:
    type: http
    url: "https://vpn.example.com/private/<random-token>/nodes.yaml"  # 受保護路徑
    interval: 3600
    path: ./providers/my-nodes.yaml
    health-check: { enable: true, url: http://www.gstatic.com/generate_204, interval: 300 }

rule-providers:
  reject:
    type: http
    behavior: domain
    format: mrs            # mihomo 二進位，大規則集載入快、體積小
    url: "https://cdn.jsdelivr.net/gh/<you>/<rules-repo>@main/reject.mrs"
    path: ./rules/reject.mrs
    interval: 86400

proxy-groups:
  - name: PROXY
    type: select
    use: [my-nodes]        # 引用 provider，而非寫死 proxies

rules:
  - RULE-SET,reject,REJECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
```

`nodes.yaml`（你自架的節點清單檔，內容就是一段 `proxies:`）：

```yaml
proxies:
  - { name: "JP-1", type: vmess, server: your.domain.tld, port: 443, uuid: <uuid>, alterId: 0, cipher: auto, tls: true, network: ws, ws-opts: { path: /v2ray } }
```

> 規則集要轉成 `.mrs` 可用 mihomo：`mihomo convert-ruleset domain yaml reject.yaml reject.mrs`。
> 不想轉就用 `format: yaml` / `text`。

## B. Shadowrocket

Shadowrocket 用的是 **Surge 風格 `.conf`**（不是 Clash YAML），自架方式有兩層：

### B-1. 自架整份遠端 config（含節點 + 規則）

把一份 `.conf` 放到你的 URL，App 內 **Config → 右上角 `+` → 從 URL 加入**，
之後點 `ⓘ` → Update 即可更新（也可設定自動更新）。`.conf` 結構：

```ini
[General]
bypass-system = true
dns-server = https://dns.google/dns-query
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, localhost, *.local

[Proxy]
JP-1 = vmess, your.domain.tld, 443, username=<uuid>, ws=true, ws-path=/v2ray, tls=true, alterId=0

[Proxy Group]
PROXY = select, JP-1
Final = select, PROXY, DIRECT

[Rule]
# 自架 / 第三方遠端規則集（純文字 .list，逐行 top-down 比對）
RULE-SET,https://cdn.jsdelivr.net/gh/<you>/<rules-repo>@main/reject.list,REJECT
RULE-SET,https://raw.githubusercontent.com/Johnshall/Shadowrocket-ADBlock-Rules-Forever/release/sr_top500_banlist.conf,REJECT
GEOIP,CN,DIRECT
FINAL,PROXY
```

### B-2. 只自架規則集（沿用既有 config）

不想搬整份設定，只想加遠端規則：在 `[Rule]` 用

```ini
RULE-SET,<你的-rules.list-url>,POLICY      # 規則集：每行含規則類型
DOMAIN-SET,<你的-domains.list-url>,POLICY  # 域名集：每行只有域名
```

規則由上往下比對，`RULE-SET` 要放在 `FINAL` 之上。現成可用的公開規則源：
[Johnshall/Shadowrocket-ADBlock-Rules-Forever](https://github.com/Johnshall/Shadowrocket-ADBlock-Rules-Forever)
（每日 8 時重建，issue #7）、[blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script)。

## Single source of truth：一次維護、全 client 套用

這是解你痛點的關鍵——**別在每個 client 各自打補丁**（重複又容易漂移），而是維護
**一份分門別類的來源**，用一個建置步驟轉成各 client 要的格式，發佈到固定 URL；
client 只指向那些 URL，**更新一次 → 全部自動套用**。

> **本架構已落地**：[daviddwlee84/clash-rules](https://github.com/daviddwlee84/clash-rules)
> —— 把本 repo legacy Clash 設定的 1272 條規則拆成 6 個分類來源（classical 格式），
> CI 驗證 + 建置後發佈到 `release` 分支，Clash（rule-providers）與
> Shadowrocket（RULE-SET）共用同一份清單。

```mermaid
flowchart TD
  subgraph repo [你的 rules repo（真相來源，git 版本化）]
    src["分類來源檔<br/>ads.list / cn.list / proxy.list / direct.list ..."]
  end
  src -->|GitHub Actions / 腳本| build["建置：轉格式"]
  build --> mrs["clash: *.mrs / *.yaml"]
  build --> srlist["shadowrocket: *.list / *.conf"]
  mrs --> cdn["發佈：CDN / nginx<br/>(固定 URL + 版本 tag)"]
  srlist --> cdn
  cdn --> c1["Clash (mihomo)"]
  cdn --> c2["Shadowrocket"]
  cdn --> c3["其他 client"]
```

落地要點：

1. **來源分類維護**：一個 repo，按用途拆檔（`ads`、`cn-direct`、`proxy`、`media`、
   `self`…），每類一個純文字清單。你日後就是往這些檔案加行，**只改這裡**。
2. **規則語法盡量共用**：Clash 與 Shadowrocket 的規則語法**高度重疊**
   （`DOMAIN-SUFFIX,...` / `IP-CIDR,...` / `GEOIP,...`），同一份 `classical` 清單兩邊常可直接用。
3. **建置轉格式**：
   - Clash 大集轉 `.mrs`：`mihomo convert-ruleset domain text ads.list ads.mrs`。
   - 節點（格式不同：YAML vs `.conf`）用 **[subconverter](https://github.com/tindy2013/subconverter)**
     從同一份訂閱輸出多端：`&target=clash` → `clash.yaml`、`&target=shadowrocket` → `shadowrocket.conf`，
     並在轉換時統一注入你的 `rule-providers` / `RULE-SET` 範本。
4. **發佈到固定 URL**：GitHub Release/Pages + jsDelivr，或推到你自家 nginx。**用版本 tag**
   （如 `@v3` 或日期）讓你能控管何時升級，避免上游一改就炸。
5. **client 端只引用 URL**：base 設定幾乎不動；要改規則就改來源 repo，client 靠 `interval`
   自動拉新（或手動 `PUT /configs?force=true` 立即套用）。

> 一句話：**規則/base 是程式碼（進 git、CI 建置、發版），client 是消費者。**
> 這正是下面那些公開 rule-set repo 的運作模式——你完全可以自己照做（見「公開維護的 rule-set」）。

## 自架 URL 的 auth（避免被直接破解/掃到）

公開規則無所謂，但**節點清單**的 URL 一旦外洩等於送人帳號。幾種由簡到強的保護：

| 方法 | 怎麼做 | client 支援 | 強度 |
|---|---|---|---|
| **隱秘長路徑（capability URL）** | URL 帶一段不可猜的隨機 token：`/p/8f3a…e21/nodes.yaml` | 全部（就是個 URL） | 低中（外洩即破，但掃不到） |
| **HTTP header token**（推薦給 Clash） | provider 設 `header: { Authorization: ['Bearer <token>'] }` | **mihomo proxy/rule-providers 支援** | 中高 |
| **nginx basic-auth** | `auth_basic` + `.htpasswd`；URL 用 `https://user:pass@host/...` | Clash/SR 多支援 URL 內帳密 | 中 |
| **IP 允許清單** | nginx `allow/deny`，只放你的出口 IP | 全部 | 中（IP 浮動時麻煩） |
| **Cloudflare Access / 簽名 URL** | R2 presigned URL、Cloudflare Access token | 看 client | 高 |
| **mTLS（雙向憑證）** | nginx `ssl_verify_client on` | 少數 client | 最高（門檻也高） |

mihomo 用 header 認證（**節點與規則 provider 都支援**）：

```yaml
proxy-providers:
  my-nodes:
    type: http
    url: "https://vpn.example.com/private/nodes.yaml"
    header:
      Authorization:
        - "Bearer <your-long-random-token>"
    interval: 3600
    path: ./providers/my-nodes.yaml
```

實務建議：

- **節點走「header token 或隱秘路徑 + HTTPS」**；規則走公開 CDN。
- **Shadowrocket 沒有自訂 header 拉 RULE-SET 的能力** → 對 SR 的私密節點，用
  **隱秘路徑** 或 **`user:pass@` basic-auth**，別期待 Bearer header。
- **token 可輪換**：外洩就換路徑/token，重新發給自己的 client（成本低）。
- 配合 nginx：給 provider 路徑單獨開 `location`，套 auth + 關目錄列表（`autoindex off`）+
  加 `Cache-Control`，並可 `add_header X-Robots-Tag noindex` 避免被索引。

## 公開維護的 rule-set（以及我們能否照做）

有，而且很成熟——這些就是「single source of truth + CI 建多格式」的現成範例：

| Repo | 內容 | 格式 | 備註 |
|---|---|---|---|
| [Loyalsoldier/clash-rules](https://github.com/Loyalsoldier/clash-rules) | reject/direct/proxy/gfw/cncidr… | Clash `text`（domain/ipcidr） | 最常用、每日更新，走 `@release` tag |
| [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat) | geosite/geoip 全套 | **`.mrs`**（mihomo 原生）/ dat | mihomo 生態核心，`meta` 分支 |
| [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script) | 超細分類（各 App/服務） | **多格式**：Clash / Shadowrocket / Surge / Quan… | **多端建置的最佳範本** |
| [Johnshall/Shadowrocket-ADBlock-Rules-Forever](https://github.com/Johnshall/Shadowrocket-ADBlock-Rules-Forever) | 去廣告 | Shadowrocket `.conf` | 每日 8 時重建（issue #7） |

直接用（Clash，jsDelivr 較穩）：

```yaml
rule-providers:
  reject: { type: http, behavior: domain, format: text, interval: 86400,
            url: "https://cdn.jsdelivr.net/gh/Loyalsoldier/clash-rules@release/reject.txt",
            path: ./ruleset/reject.yaml }
rules:
  - RULE-SET,reject,REJECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
```

**我們能不能照做？能，而且建議。** blackmatrix7 的模式正是答案：
**一份來源 → GitHub Actions → 同時產出 Clash/Shadowrocket/Surge 等格式 → 發佈到 CDN。**
你自己的 rules repo 照搬這套：你維護分類來源 + 一支轉換腳本/Action，
公開規則用 jsDelivr，私密節點走前述 auth。需要時也可**站在巨人肩上**——base 引用
Loyalsoldier/meta-rules-dat 的通用集，只自維護「你個人專屬」那幾類（self/自訂分流），
兩者疊加。

## Best practice（重點整理）

1. **規則公開、節點保護**：規則放公開 repo + CDN；節點清單放受保護路徑（隱秘 token、
   私有 repo + raw token、或 nginx basic-auth），**永遠不要 commit 含 UUID 的訂閱到公開 repo**。
2. **CDN 提升 GFW 可達性**：公開規則走 jsDelivr / Cloudflare，比直連 GitHub raw 穩。
3. **合理的 `interval`**：規則 1 天、節點 1 小時即可；別設太短打爆來源。
4. **大規則集用 `mrs`**（mihomo）：載入快、體積小。
5. **保底 fallback**：base config 內留最小 inline 規則（如 `GEOIP,CN,DIRECT` + `MATCH,PROXY`），
   萬一 provider 拉取失敗，client 仍可運作。
6. **版本化你的「真相來源」**：規則/base 進 git；節點清單由產生器輸出、不入庫。
7. **熱更新而非重啟**：改完用 `PUT /configs?force=true`（見 [API.md](API.md)）。
8. **單一真相來源 + CI 建多格式**：規則只在一個 repo 維護，靠腳本/Action 轉成各 client 格式
   再發佈——避免在每個 client 重複打補丁（解你的核心痛點）。
9. **釘版本 tag**：URL 用 `@v3` / 日期 tag，自己決定何時升級，避免上游一改就連帶炸。
10. **節點 URL 加 auth**：header token（Clash）或隱秘路徑 / basic-auth（Shadowrocket），
    token 可隨時輪換。

## 對接本專案

本專案**已經在 VPS 上跑 nginx**（[`server/compose.yml`](../../server/compose.yml) +
[`server/templates/nginx/v2ray.conf.tmpl`](../../server/templates/nginx/v2ray.conf.tmpl)），
天然就是個現成的靜態主機，可順手兼當 provider host：

- 在 nginx 加一個 `location /provider/`（建議 basic-auth 或隱秘路徑）指向一個目錄，
  放 `nodes.yaml` / 規則檔，client 端用該 URL 當 `proxy-providers` / `RULE-SET`。
- 產生器面：`just az-client` 目前輸出**靜態** `out/client/clash.yaml`（見根
  [`README.md`](../../README.md)）；可擴充成同時輸出 `nodes.yaml`（provider 版）與
  `shadowrocket.conf`，並（可選）推送到上述 nginx 路徑。
- 機敏處理沿用既有機制：[`scripts/redact_secrets.py`](../../scripts/redact_secrets.py)、
  pre-commit 的 gitleaks——確保節點/UUID 不外洩。

> 以上為方向與範例，**本次僅文檔，不改動 server / client 代碼**（協議與 nginx 變更
> 仍受 [CLAUDE.md](../../CLAUDE.md) 約束）。

## 參考

- [mihomo proxy-providers](https://wiki.metacubex.one/en/config/proxy-providers/) ／
  [rule-providers](https://wiki.metacubex.one/en/config/rule-providers/)
- [Shadowrocket 設定檔格式 / 規則系統 (DeepWiki)](https://deepwiki.com/LOWERTOP/Shadowrocket/6.1-configuration-file-format)
- [Johnshall/Shadowrocket-ADBlock-Rules-Forever](https://github.com/Johnshall/Shadowrocket-ADBlock-Rules-Forever)
  ／ [blackmatrix7/ios_rule_script](https://github.com/blackmatrix7/ios_rule_script)
- [subconverter](https://github.com/tindy2013/subconverter)
