# Clash RESTful API（external-controller, port 9090）

回答「Clash 的 API default port 9090 有 OpenAPI/Swagger 嗎？」。

簡短答案：**有 RESTful API，但官方沒有附 OpenAPI/Swagger 規格檔。**
事實上的文檔是 mihomo wiki [`/en/api/`](https://wiki.metacubex.one/en/api/)
與各家 wiki 的 External Controller 章節。

## 這個 API 是什麼

`external-controller` 開的就是這個 HTTP RESTful API，所有第三方 dashboard
（metacubexd、yacd、zashboard…）都靠它運作。我們的
[`clients/docker/config.yaml`](../../clients/docker/config.yaml) 已開：

```yaml
external-controller: 0.0.0.0:9090
external-ui: ui_pages          # 我們 vendored 的是 hinak0/yacd
# secret: "clash_secret"       # ← 目前被註解掉，見下方安全提醒
```

## 認證與監聽變體

| 設定 | 作用 |
|---|---|
| `secret: <token>` | 所有 API 呼叫需帶 `Authorization: Bearer <token>` |
| `external-controller-cors` | CORS allow-list（`allow-origins` / `allow-private-network`） |
| `external-controller-tls: 127.0.0.1:9443` | HTTPS API（需頂層 `tls` 提供憑證） |
| `external-controller-unix: mihomo.sock` | Unix socket（**不驗 secret**，靠檔案權限） |
| `external-controller-pipe: \\.\pipe\mihomo` | Windows named pipe（同上，僅同機） |

呼叫範例：

```bash
export CLASH_SECRET='your-secret-here'
curl -H "Authorization: Bearer ${CLASH_SECRET}" \
  'http://127.0.0.1:9090/configs?force=true' \
  -X PUT -d '{"path": "", "payload": ""}'
```

## 端點清單

| 端點 | 方法 | 說明 |
|---|---|---|
| `/configs` | GET / PUT / PATCH | 取得 / 重載（`?force=true`）/ 局部更新基礎設定 |
| `/configs/geo` | POST | 更新 GEO 資料庫 |
| `/proxies` | GET | 所有 proxy / proxy-group |
| `/proxies/:name` | GET / PUT | 取得單一 / 切換 selector 選用節點 |
| `/proxies/:name/delay` | GET | 對指定節點測延遲 |
| `/providers/proxies` | GET | proxy-providers 狀態 |
| `/providers/proxies/:name` | GET / PUT | 取得 / 更新某 provider |
| `/providers/proxies/:name/healthcheck` | GET | 觸發健康檢查 |
| `/rules` | GET | 目前規則 |
| `/connections` | GET / WS / DELETE | 即時連線（WS 串流）/ 關閉連線 |
| `/logs` | GET / WS | 即時日誌串流 |
| `/traffic` | GET / WS | 即時上下行 |
| `/memory` | GET / WS | 即時記憶體 |
| `/version` | GET | 核心版本 |
| `/dns/query` | GET | `?name=&type=` 查 DNS |
| `/upgrade` | POST | 升級核心 / GEO（mihomo） |
| `/debug/pprof` | GET | Go pprof（記憶體/CPU 剖析） |

> `/connections`、`/logs`、`/traffic`、`/memory` 同時支援一次性 GET 與 WebSocket 串流。
> [Observability.md](Observability.md) 的 exporter 就是吃這些 WS。

## 消費這個 API 的 dashboard

- [`metacubexd`](https://github.com/MetaCubeX/metacubexd)：mihomo 官方推薦的現代前端。
- [`yacd`](https://github.com/haishanh/yacd)：我們 vendored 在
  [`clients/docker/ui_pages/`](../../clients/docker/ui_pages/) 的就是它（[`hinak0/yacd`](https://github.com/hinak0/yacd) 分支）。
- [`zashboard`](https://github.com/Zephyruso/zashboard)：另一個社群 dashboard。

掛 dashboard 的兩種方式：`external-ui` 讓核心自己 serve（`http://<controller>/ui/`），
或獨立部署前端再填入 controller 位址 + secret。

## 「想要 OpenAPI/Swagger」怎麼辦

- **官方沒有**機器可讀的 OpenAPI/Swagger 檔，也沒有 `/swagger` 端點。
- 上面的端點表已涵蓋全部；若工具鏈真的需要 OpenAPI，可**依此表手寫**一份最小 `openapi.yaml`
  （之後若有需要，可開獨立任務產出並驗證）。本次僅記錄可行性，不產出規格檔。

## `secret` 怎麼配置與使用？有什麼選項？

`secret` 是這個 API 唯一的內建認證機制（Bearer token）。**只要 `external-controller`
綁在非 loopback 位址（如 `0.0.0.0`），就必須設 `secret`**，否則同網段任何人都能控制核心。

### 1. 設定 secret（在 config.yaml）

```yaml
external-controller: 0.0.0.0:9090
secret: "a-long-random-token"     # 建議用隨機字串，別用範例值
```

產生一個夠強的隨機 token：

```bash
openssl rand -hex 32        # 或： head -c 32 /dev/urandom | base64
```

> mihomo 也支援 `${ENV_VAR}` 形式，例如 `secret: ${CLASH_SECRET}`，可從環境變數注入，
> 避免把明文 token 寫進版本控制的設定檔。

### 2. 帶 secret 呼叫 API

所有請求加 `Authorization: Bearer <secret>` 標頭（以下用環境變數代入，避免明文）：

```bash
export CLASH_SECRET='your-secret-here'
curl -H "Authorization: Bearer ${CLASH_SECRET}" http://127.0.0.1:9090/version
```

WebSocket 端點（`/logs`、`/traffic`…）有兩種帶法：

```bash
# 標頭（程式碼內常用）
wscat -H "Authorization: Bearer ${CLASH_SECRET}" -c ws://127.0.0.1:9090/traffic
# 或 query 參數（瀏覽器/部分前端用）
ws://127.0.0.1:9090/traffic?token=<secret>
```

Dashboard（metacubexd / yacd）在登入畫面填 `API Base URL` + `Secret` 即可；
yacd 也支援 `http://host:9090/ui/?secret=<secret>` 直接帶入。

### 3. 各種存取控制選項（由寬到嚴）

| 選項 | 設定 | 適用 |
|---|---|---|
| 綁 loopback（最簡單最安全） | `external-controller: 127.0.0.1:9090` | 只在本機用 dashboard / curl；遠端用 SSH 隧道 `ssh -L 9090:127.0.0.1:9090 host` |
| 綁全網 + secret | `external-controller: 0.0.0.0:9090` + `secret:` | 需要 LAN 內其他裝置存取 |
| HTTPS API | `external-controller-tls: 0.0.0.0:9443` + 頂層 `tls` 憑證 + `secret` | 跨網路傳輸要加密 token 時 |
| Unix socket | `external-controller-unix: mihomo.sock` | 同機程式存取，**不驗 secret**，靠檔案權限 |
| CORS 收斂 | `external-controller-cors.allow-origins: [...]` | 限制哪些前端網域可呼叫（預設別用 `'*'`） |

> 提醒：Unix socket / named pipe **不檢查 secret**，安全性完全依賴檔案系統權限，
> 別把 socket 放在所有人可讀寫的目錄。

### 針對本專案現況

我們的 [`clients/docker/config.yaml`](../../clients/docker/config.yaml) 綁
**`0.0.0.0:9090` 卻把 `secret` 註解掉** —— 任何能連到該主機的人都能改路由。
建議擇一（屬未來改動，不在本研究落地）：設 `secret:`、改綁 `127.0.0.1`，或用 Unix socket。
注意 Docker 場景下若 `external-controller` 綁 `127.0.0.1` 而你又用 port mapping 暴露 9090，
要嘛在容器內綁 `0.0.0.0` 再靠 `secret` + 只 publish 到 host loopback（`127.0.0.1:9090:9090`）控管。

## 參考

- [mihomo APIs](https://wiki.metacubex.one/en/api/)
- [External Controller (Core Tutorial)](https://core-tutorial.argsment.com/mihomo/external-controller)
- [The External Controller | Clash Knowledge](https://en.clash.wiki/runtime/external-controller.html)
