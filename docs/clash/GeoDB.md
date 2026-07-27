# Geo DB 是什麼、為什麼需要

> 小科普。起因：`clients/mihomo-docker/` 的 binary 版需要手動餵一個 `geoip.metadb`，
> 官方 image 版卻不用——差別在哪、這東西誰在維護。

## 一句話

Geo DB 是一組**離線查表檔**，把「IP 位址 → 國家代碼」和「網域 → 分類」預先打包成
二進位檔。有了它，一條規則就能取代上萬條手寫的 CIDR / 網域。

## 為什麼需要

看 [`clients/mihomo-docker/config.example.yaml`](../../clients/mihomo-docker/config.example.yaml)
的最後幾行：

```yaml
rules:
  - GEOIP,CN,DIRECT     # 中國 IP 直連，不浪費 VPS 頻寬
  - MATCH,Final         # 其餘走代理
```

`GEOIP,CN` 要求核心在**每個連線建立的瞬間**回答「這個目標 IP 是不是中國」。中國大陸
分配到的 IPv4 CIDR 有數千段，且會變動——不可能寫死在 config 裡。所以核心去查一個
本地資料庫。

同一份 DB 也支撐 DNS 那段：

```yaml
dns:
  fallback-filter:
    geoip: true
    geoip-code: CN      # 解析結果若是 CN IP 就採信國內 DNS，否則採信 fallback
```

**沒有 DB 檔，這兩條都會失效**（mihomo 啟動時會噴載入失敗）。這就是 binary 版
compose 一定要掛 `geoip.metadb` 的原因。

查表是純本地行為，不會對外連線、不會洩漏你在連哪裡。

## 兩大類

| 類型 | 回答什麼 | 規則寫法 | 本專案現況 |
|------|----------|----------|------------|
| **GeoIP** | 這個 IP 屬於哪個國家 / ASN | `GEOIP,CN` / `IP-ASN,13335` | ✅ 有用到 |
| **GeoSite** | 這個網域屬於哪一類 | `GEOSITE,category-ads-all`、`GEOSITE,netflix` | ❌ 目前沒用 |

我們的 config 是手寫 `DOMAIN-SUFFIX,anthropic.com,PROXY` 這種明確規則，所以不需要
`geosite.dat`。哪天想改成 `GEOSITE,openai` 之類的分類規則，再 `./fetch-assets.sh
--with-geosite`。

## 檔案格式為什麼這麼多種

歷史包袱。同一份資料被打包成好幾種容器格式：

| 檔名 | 格式 | 誰在用 |
|------|------|--------|
| `Country.mmdb` | MaxMind MMDB | 舊版 Clash（`clients/docker/` 那份就是） |
| `geoip.metadb` | mihomo 自家精簡 MMDB | **mihomo 預設** |
| `geoip.db` | sing-box 格式 | sing-box；mihomo 也讀得懂 |
| `geoip.dat` | V2Ray protobuf | V2Ray / Xray；mihomo 需 `geodata-mode: true` |
| `geosite.dat` | V2Ray protobuf | GeoSite 分類 |
| `*.mrs` / `*.srs` | rule-set 格式 | `rule-providers`，跟 geo DB 是不同機制 |

mihomo 挑檔案的邏輯在上游 `constant/path.go` 的 `MMDB()`：它會在 config 目錄下依序
找 `Country.mmdb` / `geoip.db` / `geoip.metadb`，**三個檔名都接受**，都沒有才報錯。
所以舊 Clash 留下的 `Country.mmdb` 直接搬過來也能動。

`geodata-mode` 決定走哪條路：預設 `false` → 用 MMDB 系列；設 `true` → 改用
`geoip.dat`。另外有 lite 版本（`geoip-lite.metadb` 392 KB vs 完整版 8.7 MB），砍掉
冷門國家，適合塞不下的小裝置。

## 全世界共用一份嗎？

**不是。** 沒有官方標準，是一條社群接力的供應鏈：

```
MaxMind GeoLite2 Country CSV        原始 IP 歸屬資料（商業公司，2019 起需註冊
        │                            license key 才能下載 → 所以才有一堆鏡像）
        ▼
Loyalsoldier/geoip                  每週四重建，在 MaxMind 基礎上做修正與加料
        │                            （補 CN 段、加 PRIVATE 類別等）
        ▼
MetaCubeX/meta-rules-dat            每天 06:30 (UTC+8) 重建，用 metacubex/geo
        │                            轉成 .metadb / .db / .mrs / .srs 各種格式
        ▼
我們（fetch-assets.sh 或官方 image）
```

GeoSite 是另一條線，來源更雜：`v2fly/domain-list-community`（基礎分類）+
`Loyalsoldier/domain-list-custom` + `blackmatrix7/ios_rule_script` + GFWList 等等，
最後併成一份 `geosite.dat`。

重點是**不同發行版內容不一樣**。同樣叫 `geoip.dat`，v2fly 官方版、Loyalsoldier 版、
xishang0128 版對「哪些 IP 算 CN」的判斷就有出入。這是社群共識，不是標準。

## 所以它會過期

IP 分配一直在變（RIR 重新配發、機房換段），加上 CDN / anycast 本來就沒有單一國籍、
雲端 IP 常被標錯國家。上游每天重建就是為了追這個。實務影響：舊 DB 會讓某些流量走錯
邊——中國 IP 被判成境外而繞道 VPS（慢），或反過來境外 IP 被判成 CN 而直連（連不上）。

三種更新方式：

1. **`./fetch-assets.sh --force`** —— binary 版，手動重抓。
2. **mihomo 自動更新** —— config 加這兩行（預設是關的）：
   ```yaml
   geo-auto-update: true
   geo-update-interval: 24    # 小時；這是預設值
   ```
   在 GFW 主機上要留意：更新時要能連到 GitHub，可用 `geox-url` 指向鏡像。
3. **重拉 image** —— 見下面的坑。

## ⚠️ 官方 image 的 geo data 是「build 當下」的快照

[上游 Dockerfile](https://github.com/MetaCubeX/mihomo/blob/Meta/Dockerfile) 是在
**build 階段**把 geo 檔抓進去的：

```dockerfile
RUN wget -O /mihomo-config/geoip.metadb https://.../meta-rules-dat/releases/download/latest/geoip.metadb
```

所以 `docker-compose.yaml` 釘著 `metacubex/mihomo:v1.19.29`，意味著 geo data 也一起
凍結在 v1.19.29 發佈那天。跑久了資料會愈來愈舊——這是釘版本的代價，不是 bug。

要嘛定期 bump image tag，要嘛在 config 開 `geo-auto-update: true` 讓它自己覆蓋掉內建
的那份。諷刺的是 binary 版反而沒這問題：`fetch-assets.sh` 每次抓的都是上游 `latest`
tag 的當日產物。

## 本專案怎麼拿到它

| 版本 | 來源 |
|------|------|
| `docker-compose.yaml`（預設） | 官方 image 已內建，不用管 |
| `docker-compose.binary.yaml` | [`./fetch-assets.sh`](../../clients/mihomo-docker/fetch-assets.sh)，抓 `geoip.metadb` 並驗 `.sha256sum` |
| `clients/docker/`（舊 Clash） | repo 內 tracked 的 `Country.mmdb`，很舊，僅供舊 stack 用 |

## 相關

- [`clients/mihomo-docker/README.md`](../../clients/mihomo-docker/README.md) —— 兩個 compose 的取捨。
- [SelfHostProviders.md](SelfHostProviders.md) —— `rule-providers` 自架：另一種「規則不寫死在 config」的做法，跟 geo DB 互補。
- [ConfigManagement.md](ConfigManagement.md) —— 規則 URL 化的整體策略。
