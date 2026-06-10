# Clash / Mihomo 研究筆記

Client 端 Clash 生態的研究整理。**這些是評估/研究筆記，不是部署文檔**
——本專案只提供 V2Ray VMess server，client 由使用者自選；repo 內
[`clients/`](../../clients/) 只是範例。本次研究**不改動任何 client 運行代碼**。

想直接抄一套組合？先看 **[BestPractice.md](BestPractice.md)**（核心 mihomo + 殼 Clash
Verge Rev / Clash Mi + 協議建議 + terminal 工作流）。各主題細節：

| # | 文檔 | 一句話結論 |
|---|---|---|
| ★ | [BestPractice.md](BestPractice.md) | 一套可照抄的 combo：**mihomo 核心 + Clash Verge Rev/Clash Mi 殼（皆開源）+ providers 配置 + 檔案管結構/API 管切換**；協議理想型是 VLESS+Vision+REALITY。 |
| 1 | [Core.md](Core.md) | 我們現用的 `Kuingsmile/clash-core` 已凍結；**mihomo (Clash.Meta)** 是 2026 主流，YAML 相容、換核心即可。**ShellCrash 不是核心**，是安裝/管理工具。 |
| 2 | [Observability.md](Observability.md) | Clash **無原生 Prometheus/OTel 輸出**；用社群 exporter（metrics）+ Alloy/promtail（logs）橋接到 `grafana/otel-lgtm`。 |
| 3 | [API.md](API.md) | port 9090 有 **RESTful API 但官方無 OpenAPI/Swagger**；端點齊全，需自設 `secret`（我們目前綁 `0.0.0.0` 卻沒設，是隱憂）。 |
| 4 | [Clients.md](Clients.md) | **一個 server、多個 client**：核心(mihomo) / GUI(Clash Verge Rev) / TUI(clashtui) / 行動端(Clash Mi/FlClash) / dashboard 分層；對應 issue #6/#8。 |
| 5 | [ConfigManagement.md](ConfigManagement.md) | 系統化 = base 設定瘦身 + 節點/規則 **URL 化（proxy-providers / rule-providers）** + 用 API 熱更新；terminal 改配置 TUI/檔案/API 三選一。 |
| 6 | [../ProtocolEvaluation.md](../ProtocolEvaluation.md) | VMess 已非首選；**VLESS+Vision+REALITY** 抗 GFW 最強，含偵測風險排序與選型矩陣。 |

## 與本專案的關係

- Server 端（VPS 上的 nginx + v2ray）見根 [`README.md`](../../README.md) 與
  [`docs/`](../) 其他文檔；server 日誌輪替見 [`docs/LOG-ROTATION.md`](../LOG-ROTATION.md)。
- Client 範例見 [`clients/docker/`](../../clients/docker/)、[`clients/cli/`](../../clients/cli/)；
  兩者目前綁已凍結的 `Kuingsmile/clash-core`，長期建議統一遷往 **mihomo**（見 [Core.md](Core.md)）。
- 相關替代管理面板的舊筆記見 [`docs/old/XrayUI.md`](../old/XrayUI.md)。
