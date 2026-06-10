---
name: Clash Research Docs
overview: 把 5 個 Clash/Mihomo 研究主題整理成 docs/clash/ 下的多個筆記文檔（純文檔、不改 client 代碼），並更新 README 文檔索引。
todos:
  - id: core
    content: 撰寫 docs/clash/Core.md：Mihomo vs 現用 Kuingsmile/clash-core vs 原版 Clash/Premium，釐清 ShellCrash 非核心，含遷移 caveat
    status: completed
  - id: observability
    content: 撰寫 docs/clash/Observability.md：log/metrics 接 Grafana(otel-lgtm) 的 exporter 與 Loki 路徑 + mermaid 拓撲
    status: completed
  - id: api
    content: 撰寫 docs/clash/API.md：9090 RESTful API 端點表、無官方 OpenAPI、認證/CORS、現有 config 安全提醒
    status: completed
  - id: clients
    content: "撰寫 docs/clash/Clients.md：core/GUI/TUI/dashboard 分類表，對應 issue #6/#8 與 clashverge.dev，平台選型建議"
    status: completed
  - id: configmgmt
    content: 撰寫 docs/clash/ConfigManagement.md：config.yaml schema + proxy-providers/rule-providers URL 化 + 熱更新 API，對接本專案現況
    status: completed
  - id: index
    content: 撰寫 docs/clash/README.md 索引，並更新根 README.md 的 docs 佈局說明
    status: completed
isProject: false
---

# Clash / Mihomo 研究文檔整理

只新增/編輯 Markdown 文檔。不改動 `clients/` 任何運行代碼。新增一個 `docs/clash/` 子目錄（仿照現有 `docs/old/`），按主題拆成 5 篇 + 1 篇索引，並把現有散落在 `clients/cli/README.md`、`docs/old/XrayUI.md` 的相關連結引用進來（不刪原檔）。

## 背景：專案現況（已查證）

- Server 端是 V2Ray **VMess over WebSocket + TLS**（不在本次範圍，僅作相容性參照）。
- Client 端 `clients/docker/Dockerfile` 與 `clients/cli/` 目前用的是 **`Kuingsmile/clash-core` v1.18.0** — 這是原版 Dreamacro Clash 的維護鏡像/分支，原版已於 **2023-11 封存唯讀**。
- `clients/docker/config.yaml` 把節點、proxy-groups、rules **全部寫死 inline**；`external-controller: 0.0.0.0:9090` 但 `secret` 被註解掉（安全隱憂，會在 API 文檔點出）。
- `ui_pages/` 是 vendored 的 `hinak0/yacd` dashboard。

## 文檔結構（docs/clash/）

對應使用者 5 個問題，逐篇拆分：

### 1. `docs/clash/Core.md`（問題 1：Mihomo vs 現版 / ShellCrash 釐清）
- 三條血脈對照：**原版 Clash（Dreamacro，2023-11 封存）** → 我們現用的 **Kuingsmile/clash-core v1.18.0**（同一系，凍結）；**Clash Premium**（閉源、TUN/profile tracing，亦凍結）；**Mihomo / MetaCubeX（前稱 Clash.Meta）** = 2026 事實標準、持續維護。
- Mihomo 新增能力：Hysteria2、TUIC v5、VLESS/REALITY、SS2022、ShadowTLS；DNS（DoH/DoT/DoQ、fake-ip-filter）；更豐富的 rule-set/rule-providers；YAML 向後相容（換 binary 即可）。
- **釐清命名混淆**：問題裡的「Shell Crash/Clash」指的是 `juewuy/ShellCrash`（與 `ShellClash`）——它**不是核心**，而是 Linux/OpenWrt 上的安裝/管理 TUI 腳本，底層可跑 **mihomo 或 sing-box**（做透明代理/旁路由）。
- 對本專案的遷移含義：VMess+WS+TLS 在 mihomo 上原樣可用；唯一 caveat 是 `alterId: 64` 舊式 VMess MD5 認證 → 建議改 `alterId: 0`（VMess AEAD）。

### 2. `docs/clash/Observability.md`（問題 2：log 進 Grafana / Otel-LGTM）
- 結論：**Clash/mihomo 沒有原生 Prometheus/OTel 輸出**，需橋接。兩個資料面：
  - 文字日誌（stdout/檔案，`log-level` 控制）。
  - API 串流：`/logs`、`/traffic`、`/memory`、`/connections`（皆 GET/WS）。
- 兩條接入路徑：
  - **Metrics → Prometheus/Mimir**：社群 exporter —
    - `kookxiang/prometheus-mihomo-exporter`（WS `/connections`，按 ASN/Client/Host/Proxy 分組，預設 `:25301`）。
    - `zxh326/clash-exporter`（含 Grafana dashboard id `18530`；`clash_download_bytes_total`、`clash_active_connections`、tracing histograms — 但 tracing 需 premium `profile.tracing`）。
    - `elonzh/clash_exporter`（proxy delay、up/down）。
  - **Logs → Loki**：用 Grafana Alloy / promtail / otel-collector filelog 抓容器 stdout，或消費 `/logs` WS。
- 用 `grafana/otel-lgtm` 單體鏡像（OTel Collector + Loki + Tempo + Prometheus + Grafana）做 all-in-one；附一張 mermaid 拓撲：`mihomo → exporter → prometheus`、`mihomo stdout → alloy → loki`、`→ otel-lgtm/grafana`。
- 註明這是 **client 端**可觀測性；server 端（VPS 上 nginx/v2ray）日誌已由 `docs/LOG-ROTATION.md` 處理，可另議是否一併送 LGTM。

### 3. `docs/clash/API.md`（問題 3：9090 是否有 OpenAPI/Swagger）
- 結論：external-controller 預設 `9090` 提供 **RESTful Clash API**，但**官方沒有附 OpenAPI/Swagger 規格檔**；mihomo wiki（`wiki.metacubex.one/en/api/`）是事實上的文檔。
- 端點清單（GET/PUT/PATCH/WS/DELETE）：`/configs`、`/proxies`(+`/:name`、`/:name/delay`)、`/providers/proxies`(+healthcheck)、`/rules`、`/connections`、`/logs`、`/traffic`、`/memory`、`/version`、`/dns/query`、`/configs/geo`、`/upgrade`、`/debug/pprof`。
- 認證：`Authorization: Bearer ${secret}`；CORS（`external-controller-cors`）；變體 `external-controller-tls` / `-unix` / `-pipe`。
- 消費此 API 的 dashboard：metacubexd、yacd（我們 vendored 的就是它）、zashboard。
- **安全提醒**：我們的 `config.yaml` 綁 `0.0.0.0:9090` 卻沒設 `secret` → 建議補 `secret` 或改綁 loopback。
- 想要 OpenAPI 的選項：官方無 → 可依端點表手寫一份最小 OpenAPI（之後若需要可獨立任務）。

### 4. `docs/clash/Clients.md`（問題 4：各種 server/client 釐清）
- 框架：**一個 server（我們的 VMess/WS）、多個 client**。給分類表：
  - **核心 (core)**：mihomo（meta，主流）、sing-box、`Watfaq/clash-rs`、原版 clash（已死）、Kuingsmile 鏡像。
  - **GUI**：**Clash Verge Rev**（Tauri，內建 mihomo，clashverge.dev）、FlClash、Stash、`Lythrilla/NeedyClash`（issue #6）；ClashX/Pro、CFW（皆已停更）。
  - **TUI/CLI**：`JohanChane/clashtui`、`wzk0/clash_tui`（Termux，皆 issue #8）、`juewuy/ShellCrash`（安裝/管理 TUI）、clash-core CLI。
  - **Web Dashboard**（純前端、走 API）：metacubexd、yacd、zashboard。
- 直接對應 GitHub issue #6 / #8 與 clashverge.dev。
- 給「按平台選型」建議：桌面日常 → Clash Verge Rev；無頭 Linux/伺服器 → mihomo + clashtui 或 ShellCrash；本地 docker 快測 → 現有 `clients/docker`（建議核心升級 mihomo）。

### 5. `docs/clash/ConfigManagement.md`（問題 5：系統性配置管理）
- **a. config.yaml schema**：列出頂層區塊（general/inbound、dns、proxies、proxy-groups、proxy-providers、rules、rule-providers、tun、sniffer）；編輯器用 `# yaml-language-server: $schema=` 掛 mihomo JSON schema 取得補全/校驗；指向 mihomo wiki config 參考。
- **b. 用 URL 管理 rules/profiles + 熱更新**：
  - `proxy-providers`：從訂閱 URL 拉節點，`interval` 自動刷新 + `health-check`。
  - `rule-providers`：從 URL 拉 rule-set（`behavior` domain/ipcidr/classical；`format` yaml/text/mrs；`url`/`path`/`interval`）。
  - **熱更新**：`PUT /configs?force=true`（重載檔案）/ `PATCH /configs`（局部）/ `/providers/*` healthcheck/update；GUI（Verge）背後即如此，另支援 Merge/Script profile enhancement、排程更新。
  - 多訂閱合併/轉換：subconverter、Verge 多訂閱合併。
- **對接本專案**：現在 `config.yaml` 是全 inline；系統化做法 = 瘦身成 base config + 把節點移到 `proxy-providers`、規則移到 `rule-providers`（URL 化）；並指出 `just az-client` 目前輸出靜態 `clash.yaml`，未來可改輸出 provider 版（僅記錄為後續方向，不在本次實作）。

### 6. `docs/clash/README.md`（索引）
- 一頁總覽 + 5 篇連結 + 一句話 TL;DR 各篇結論。

## 同步更新（文檔層）

- 根 `README.md` 的「Repo layout」`docs/` 該列補上 `clash/` 子目錄說明。
- `docs/old/XrayUI.md`、`clients/cli/README.md` 的 Clash 相關連結在新文檔中收編引用（保留原檔，不刪）。

## 不做（明確排除）

- 不改 `clients/docker/Dockerfile`、`config.yaml`、`docker-compose*.yaml` 或任何 client 運行代碼。
- 不新增 exporter / Grafana compose 實作（僅在文檔中給範例與拓撲）。
- 不手寫 OpenAPI 規格檔（僅在 API 文檔說明可行性）。
