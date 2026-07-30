# Clash / Mihomo 研究筆記

Client 端 Clash 生態的研究整理。**這些是評估/研究筆記，不是部署文檔**
——本專案 server 端提供 VLESS+REALITY（legacy: VMess+WS），client 由使用者自選；repo 內
[`clients/`](../../clients/) 只是範例。本次研究**不改動任何 client 運行代碼**。

想直接抄一套組合？先看 **[BestPractice.md](BestPractice.md)**（核心 mihomo + 殼 Clash
Verge Rev / Clash Mi + 協議建議 + terminal 工作流）。各主題細節：

| # | 文檔 | 一句話結論 |
|---|---|---|
| ★ | [BestPractice.md](BestPractice.md) | 一套可照抄的 combo：**mihomo 核心 + Clash Verge Rev/Clash Mi 殼（皆開源）+ providers 配置 + 檔案管結構/API 管切換**；協議 VLESS+Vision+REALITY 已是 server 端現況。 |
| 1 | [Core.md](Core.md) | `Kuingsmile/clash-core` 已凍結且**不支援 REALITY**；換 **mihomo (Clash.Meta)** 從建議變成必要。**ShellCrash 不是核心**，是安裝/管理工具。 |
| 2 | [Observability.md](Observability.md) | Clash **無原生 Prometheus/OTel 輸出**；用社群 exporter（metrics）+ Alloy/promtail（logs）橋接到 `grafana/otel-lgtm`。 |
| 3 | [API.md](API.md) | port 9090 有 **RESTful API 但官方無 OpenAPI/Swagger**；端點齊全，需自設 `secret`（我們目前綁 `0.0.0.0` 卻沒設，是隱憂）。 |
| 4 | [Clients.md](Clients.md) | **一個 server、多個 client**：核心(mihomo) / GUI(Clash Verge Rev) / TUI(clashtui) / 行動端(Clash Mi/FlClash) / dashboard 分層；對應 issue #6/#8。 |
| 5 | [ConfigManagement.md](ConfigManagement.md) | 系統化 = base 設定瘦身 + 節點/規則 **URL 化（proxy-providers / rule-providers）** + 用 API 熱更新；terminal 改配置 TUI/檔案/API 三選一。 |
| 5b | [SelfHostProviders.md](SelfHostProviders.md) | **如何自架 provider**：single source of truth（一次維護全 client 套用）、Clash + Shadowrocket 兩格式、URL 的 auth 方法、公開 rule-set（Loyalsoldier / blackmatrix7）與照做方式；對接本專案 nginx。 |
| 6 | [../ProtocolEvaluation.md](../ProtocolEvaluation.md) | 為何 default 改成 **VLESS+Vision+REALITY**：實機稽核（六年沒更新的 core、`alterId: 64`）+ 偵測風險排序與選型矩陣。 |
| 7 | [GeoDB.md](GeoDB.md) | 小科普：`GEOIP,CN` 背後的離線查表檔是什麼、**沒有全球統一版本**（MaxMind → Loyalsoldier → meta-rules-dat 的社群供應鏈），以及官方 image 的 geo data 會隨釘版本一起凍結。 |

## 與本專案的關係

- Server 端（VPS 上的 Xray + nginx）見根 [`README.md`](../../README.md) 與
  [`docs/`](../) 其他文檔；server 日誌輪替見 [`docs/LOG-ROTATION.md`](../LOG-ROTATION.md)。
- Client 範例：**維護中的是 [`clients/mihomo-docker/`](../../clients/mihomo-docker/)**
  （已含 VLESS+REALITY proxy 與 CN 端 DNS 設定）；桌面請用
  [**Clash Verge Rev**](https://github.com/clash-verge-rev/clash-verge-rev)（見
  [`clients/cli/README.md`](../../clients/cli/README.md)）。
  [`clients/docker/`](../../clients/docker/) 仍綁凍結的 `Kuingsmile/clash-core`
  v1.18，**連不上現在的 REALITY server**，僅供 `vpn_protocol: vmess_ws` 或考古用。
- 相關替代管理面板的舊筆記見 [`docs/old/XrayUI.md`](../old/XrayUI.md)。
