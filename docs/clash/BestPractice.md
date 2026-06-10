# 一套 Best-Practice Combo（2026）

把前面各篇的結論收斂成一套可直接照抄的組合，回答「來一套 best practice combo」、
「terminal 怎麼改配置」、「行動端怎麼選」。

這是**推薦組合**，不是本專案現況。**Server 端協議遷移（VLESS/Reality）依
[CLAUDE.md](../../CLAUDE.md) 目前不在範圍內**——把它列進來是為了畫出「理想型」與
逃生路線（見 [ProtocolEvaluation.md](../ProtocolEvaluation.md)）。

## 推薦組合一覽

| 層 | 推薦 | 為何 |
|---|---|---|
| **Server 協議** | `VLESS + XTLS-Vision + REALITY`（Xray-core / sing-box） | 2026 抗 GFW 主動探測最強；本專案現為 VMess+WS+TLS（GFW 外仍堪用） |
| **Client 核心** | **mihomo**（開源、MetaCubeX） | 事實標準、持續維護、協議全（見 [Core.md](Core.md)） |
| **桌面殼** | **Clash Verge Rev**（開源 GPL-3.0、官方 Releases、內建 mihomo） | 省心、活躍、可從 UI 更新核心 |
| **行動端** | iOS/Android：**Clash Mi** 或 **FlClash**（皆開源、mihomo） | 避開閉源信任問題（見 [Clients.md](Clients.md)） |
| **無頭 Linux** | mihomo + **clashtui**（TUI），或 ShellCrash | 管理 profile/切換/訂閱更新 |
| **觀測/控制** | metacubexd / zashboard（走 9090 API） | 看流量/日誌/切節點（見 [API.md](API.md)） |
| **配置管理** | base 設定 + **proxy-providers / rule-providers（URL 化）** + 熱重載 | 可版本控管、自動更新（見 [ConfigManagement.md](ConfigManagement.md)） |

```mermaid
flowchart LR
  subgraph srv [Server (VPS)]
    reality["Xray-core<br/>VLESS+Vision+REALITY<br/>(理想型)"]
    vmess["v2ray VMess+WS+TLS<br/>(本專案現況)"]
  end

  subgraph cli [Client]
    core["mihomo 核心"]
    desktop["Clash Verge Rev (桌面)"]
    mobile["Clash Mi / FlClash (行動)"]
    tui["clashtui (無頭 Linux)"]
    dash["metacubexd / zashboard"]
    desktop --> core
    mobile --> core
    tui --> core
    dash -->|"API :9090"| core
  end

  core --> srv
```

## 為什麼這樣配

- **核心與殼分離、兩端都選開源**：核心看得到你全部流量，固定用開源 mihomo；
  殼也盡量開源（Verge Rev / Clash Mi / FlClash），降低信任成本（見
  [Clients.md](Clients.md) 的「非開源 client 信任問題」）。
- **協議**：日常在 GFW 外，VMess+WS+TLS 夠用；主力情境在大陸且常被封，才值得遷
  VLESS+Vision+REALITY（見 [ProtocolEvaluation.md](../ProtocolEvaluation.md) 的觸發點）。
- **配置**：別把節點/規則寫死，URL 化成 providers + 熱重載，多端共用同一份可自動更新設定。
  自己 host 這些 URL 的做法（含 Shadowrocket）見 [SelfHostProviders.md](SelfHostProviders.md)。

## terminal 要用 TUI、編輯檔案、還是 API？

三者並用，分工明確（完整見 [ConfigManagement.md](ConfigManagement.md)）：

- **結構性變更**（加節點/規則、改 dns）→ **編輯 `config.yaml`**（真相來源、進 git）
  → `PUT /configs?force=true` 熱重載。
- **無頭伺服器日常管理**（多 profile、切換、更新訂閱）→ **TUI（clashtui）**，它寫檔 + 套用。
- **臨時操作**（切節點、改 mode、測延遲、看流量）→ **API / dashboard**，但**多為暫時**，
  reload 後回到檔案設定。

一句話：**檔案管結構（持久、版本化），TUI/API 管日常切換（即時）。**

## 對本專案的落地建議（不改協議）

在維持 VMess 的前提下，仍可往這套 best practice 靠攏：

1. Client 核心從凍結的 `Kuingsmile/clash-core` 升級到 **mihomo**（[Core.md](Core.md)）。
2. 桌面改用 **Clash Verge Rev**、行動端用 **Clash Mi / FlClash**。
3. [`clients/docker/config.yaml`](../../clients/docker/config.yaml) 設 `secret`、
   `alterId: 0`、隨機 WS path（[API.md](API.md) / [Core.md](Core.md)）。
4. 設定 URL 化：節點走 proxy-providers、規則走 rule-providers（[ConfigManagement.md](ConfigManagement.md)）。
5. Server 協議遷移（VLESS+Reality）僅在 [ProtocolEvaluation.md](../ProtocolEvaluation.md)
   的觸發點成立時才動。

## 參考

- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) ／
  [Clash Mi](https://github.com/KaringX/clashmi) ／ [FlClash](https://github.com/chen08209/FlClash)
- 本目錄其餘各篇：[Core](Core.md)、[Clients](Clients.md)、[API](API.md)、
  [ConfigManagement](ConfigManagement.md)、[Observability](Observability.md)
  ／ [ProtocolEvaluation](../ProtocolEvaluation.md)
