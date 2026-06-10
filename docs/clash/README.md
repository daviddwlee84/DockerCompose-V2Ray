# Clash / Mihomo 研究筆記

Client 端 Clash 生態的研究整理。**這些是評估/研究筆記，不是部署文檔**
——本專案只提供 V2Ray VMess server，client 由使用者自選；repo 內
[`clients/`](../../clients/) 只是範例。本次研究**不改動任何 client 運行代碼**。

對應使用者提出的 5 個問題：

| # | 文檔 | 一句話結論 |
|---|---|---|
| 1 | [Core.md](Core.md) | 我們現用的 `Kuingsmile/clash-core` 已凍結；**mihomo (Clash.Meta)** 是 2026 主流，YAML 相容、換核心即可。**ShellCrash 不是核心**，是安裝/管理工具。 |
| 2 | [Observability.md](Observability.md) | Clash **無原生 Prometheus/OTel 輸出**；用社群 exporter（metrics）+ Alloy/promtail（logs）橋接到 `grafana/otel-lgtm`。 |
| 3 | [API.md](API.md) | port 9090 有 **RESTful API 但官方無 OpenAPI/Swagger**；端點齊全，需自設 `secret`（我們目前綁 `0.0.0.0` 卻沒設，是隱憂）。 |
| 4 | [Clients.md](Clients.md) | **一個 server、多個 client**：核心(mihomo) / GUI(Clash Verge Rev) / TUI(clashtui) / dashboard(metacubexd/yacd) 分層；對應 issue #6/#8。 |
| 5 | [ConfigManagement.md](ConfigManagement.md) | 系統化 = base 設定瘦身 + 節點/規則 **URL 化（proxy-providers / rule-providers）** + 用 API 熱更新。 |

## 與本專案的關係

- Server 端（VPS 上的 nginx + v2ray）見根 [`README.md`](../../README.md) 與
  [`docs/`](../) 其他文檔；server 日誌輪替見 [`docs/LOG-ROTATION.md`](../LOG-ROTATION.md)。
- Client 範例見 [`clients/docker/`](../../clients/docker/)、[`clients/cli/`](../../clients/cli/)；
  兩者目前綁已凍結的 `Kuingsmile/clash-core`，長期建議統一遷往 **mihomo**（見 [Core.md](Core.md)）。
- 相關替代管理面板的舊筆記見 [`docs/old/XrayUI.md`](../old/XrayUI.md)。
