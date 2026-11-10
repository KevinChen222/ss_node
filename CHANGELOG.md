# 修改記錄

## 2026-11-09 — SS 完整分享連結與 Sub-Store

版本：`proxyall 1.7.21`、`sb.sh 20-kevin.41`。

- SS 分享連結攜帶完整 smux JSON、UDP 開關及 ShadowTLS 插件參數，創建、查看與聚合訂閱使用相同連結；取消顯示 YAML 複製流程。
- 提供 Sub-Store 腳本操作，從原始 SS 連結恢復多路復用配置，驗證官方 2.44.5 SS 解析器及 mihomo 匯出器保留五種 SS 節點的參數。
- 本機 SS 連結導入保留 Multiplex 與 Padding；查看 ShadowTLS 節點時使用外層監聽地址和內層 SS 憑據。

## 2026-11-09 — SS 多路復用與裸 VLESS 匯出

版本：`proxyall 1.7.20`、`sb.sh 20-kevin.40`。

- 新建 SS 節點同步啟用服務端 Multiplex 和 mihomo smux，採用 h2mux、最多 4 條連線；Padding 選項與兩端配置一致。
- 創建及查看 SS 節點時顯示完整 mihomo YAML，包含多路復用與 ShadowTLS 參數。
- 明確裸 VLESS 的選單、YAML 與分享連結，沿用單節點及批量創建入口。
- 測試覆蓋 SS 變體配置、YAML 顯示、裸 VLESS 連結重建、真實內核並發上下載、連線復用及 SS2022 至裸 VLESS 代理鏈。

## 2026-11-09 — XHTTP XMUX 並發數

版本：`proxyall 1.7.19`、`sb.sh 20-kevin.39`。

- 添加 XHTTP 節點時詢問每條連線的 XMUX 最大並發數，預設為 1，無效輸入可重新填寫。
- mihomo YAML 與分享連結攜帶所選並發數，連線可複用時間為 1800 秒；修改端口時保留並發數。

## 2026-11-06 — 日誌輪轉與備份保留

版本：`proxyall 1.7.18`、`sb.sh 20-kevin.38`、`deploy.sh 2026.11.06-local18`。

- 每分鐘檢查受管檔案日誌，超過 150 MiB 時輪轉並保留一份日誌備份。
- 腳本、核心及配置備份按來源保留最近一份，清理歷史備份；保留證書歸檔。
- systemd 服務標準輸出接入檔案輪轉，現有服務重啟後生效；日誌選單同時顯示 journal 和檔案。
- 安裝及更新時配置自動維護，提供維護任務修復與手動清理命令。

## 2026-11-06 — Reality 域名與證書供 XHTTP 複用

版本：`proxyall 1.7.17`、`sb.sh 20-kevin.37`。

- 修正已刪除 Reality 節點的受管 Nginx 源站阻擋同域名 XHTTP 的問題。
- 複用有效證書及私鑰，保留 HTTP-01 續期入口；停用源站前檢查主配置和中轉引用，備份配置，失敗時恢復。
- 保留節點刪除時的證書保留行為與證書管理的引用保護。
- 11 項針對性測試涵蓋有效證書複用、受管源站、主節點與中轉引用、自訂站點保護及故障恢復。

## 2026-11-06 — VLESS XHTTP TLS / HTTP/2

版本：`proxyall 1.7.16`、`sb.sh 20-kevin.36`。

- 新增 XHTTP 節點入口，沿用伺服器地址、域名、端口、路徑與名稱的互動流程，獨立下載及校驗官方 Xray 核心。
- 支援 Nginx TLS / H2、stream-up 與 HAProxy SNI 共用 443，匯出 mihomo XHTTP YAML 及分享連結。
- 接入節點查看、刪除、修改端口、服務管理及失敗回復；保留同機網站、Emby 路由與證書。
- Linux 實測 Xray 26.10.31、mihomo 1.19.33、Nginx 1.24.0、HAProxy 2.8.30；涵蓋 1 MiB 上下載、TLS H2 共用入口、生命週期與故障回復，並通過現有 Reality 回歸測試。

## 2026-10-31 — VLESS 導入校驗與 Reality 中轉探測

版本：`proxyall 1.7.15`、`sb.sh 20-kevin.35`、`advanced_relay.sh 16-kevin.14`。

- 拒絕不支援的 VLESS Encryption 與 Reality pqv 參數，包括重複參數中的不支援值。
- Reality 中轉寫入前，以臨時回環代理探測落地連通性；失敗時保留現有配置，提示身份驗證與握手相容性問題。
- Linux 回環測試涵蓋 sing-box 成功連線、錯誤 short ID，以及 Xray 26.10.31 的相容性拒絕。

## 2026-10-26 — chrony 自動安裝與啟用

版本：`proxyall 1.7.14`、`sb.sh 20-kevin.34`。

- systemd 校時失敗或未確認同步時，安裝缺少的 chrony，啟用服務及開機自啟，再以 chronyc 確認同步。
- 支援 chrony.service 與 chronyd.service；安裝、服務或同步失敗時繼續嘗試備用校時方式。

## 2026-10-26 — 自動校時與 HTTPS 時間校驗

版本：`proxyall 1.7.13`、`sb.sh 20-kevin.33`。

- 自動校時僅在系統確認 NTP 已同步時跳過，不再以年份判定時間準確。
- HTTPS 校時直連來源，加入唯一查詢參數及禁止快取標頭，拒絕帶有非零 Age 或無效 Date 的回應。
- 伺服器兩條 SS2022 中轉鏈路及直接落地測試均返回 HTTP 204；當次測試未重現斷連。

## 2026-10-17 — 校時回退修復

版本：`proxyall 1.7.12`、`sb.sh 20-kevin.32`。

- `sb.sh`：修復 systemd 環境中 `timedatectl` 失敗便直接結束校時的問題；啟用服務後限次確認 `NTPSynchronized`。
- 校時失敗依序嘗試現有 chrony 服務、ntpdate、限時單次 chronyd，再以 Google／Cloudflare HTTPS Date 校時；不安裝額外軟體。
- 保留各校時方式的錯誤訊息，能辨識缺少 NTP 服務、網路失敗和系統時間修改權限不足；成功後才詢問每日任務。
- `tests/time_sync.sh` 擴充至 22 項模擬測試且全部通過，涵蓋 NTP 不支援、服務未確認同步、chrony 服務、HTTPS 來源切換、缺少 Date 及權限失敗；語法、套件 SHA-256 與差異檢查通過。未連線操作使用者的 VPS。

## 2026-10-17

版本：`proxyall 1.7.11`、`sb.sh 20-kevin.31`、`advanced_relay.sh 16-kevin.13`。

### 時間同步

- `sb.sh` 選單 11：手動同步成功後詢問是否新增每日任務，預設否；任務以伺服器本地時間每日執行。
- `sync-time` 提供非互動校時入口；重複設定更新同一任務，卸載時清除，校時失敗回報錯誤。

### 選單 17 轉發修復

| 問題 | 修改位置與行為 |
| --- | --- |
| 清空中轉連帶刪除端口轉發 | `advanced_relay.sh`：`_clear_all_relays_locked` 依中轉路由及元資料清理，保留端口轉發；規則集經 `_ruleset_render clear` 清理。 |
| 刪除復用入口誤刪同端口其他出站 | `_delete_relay_locked` 僅刪除選定路由的出站 Tag，取消按端口後綴推斷並刪除出站。 |
| 重啟、配置或 YAML 寫入失敗未回滾 | `_relay_run_transaction` 為刪除、改端口、清空建立備份，失敗恢復主配置、中轉、連結、YAML、nftables 及已解除的共享入口登記。恢復檔案失敗時保留 `.relay-txn.*` 備份。 |
| UDP 入口改端口漏查衝突 | `_modify_relay_port_locked` 按 TCP／UDP 檢查佔用，另檢查 UDP 端口轉發和 Hysteria2 跳躍範圍衝突。 |
| 改端口後資料不同步 | 同步監聽端口、`public_port`、`backend_port`、分享連結、節點名稱及 YAML；JSON 字串以 jq 參數傳入。 |
| TUIC 分享連結的憑證選項遺失 | `parser.sh`：`_normalize_outbound` 支援 `allow_insecure`，保留原有選項優先序。 |

`sb.sh`、`advanced_relay.sh`、`proxyall` 的版本與組件 SHA-256 已配套更新。

### 驗證與入口

結果：63 項轉發測試、11 項時間同步測試及下列靜態檢查全部通過。

- `tests/time_sync.sh`：11 項模擬測試。
- `tests/forwarding.py`：63 項測試，核心為 sing-box 1.14.3；含真實 TCP／UDP、IPv6 TCP、八種出站、四種中轉入口、復用入口、Token／分享連結、引擎切換、DNS 刷新及故障回滾。
- `bash -n` 語法檢查、`proxyall` 的 `pa_validate_bundle` 與 `git diff --check`。
- 網路測試在獨立使用者／網路命名空間執行；systemd／OpenRC、HAProxy 實機啟停與開機持久化未實測。HAProxy 登記恢復及服務失敗以模擬呼叫驗證。

於專案根目錄執行：

```bash
bash tests/time_sync.sh
PROXYALL_TEST_PARENT_NETNS="$(readlink /proc/self/ns/net)" \
  unshare -Urn python3 tests/forwarding.py --core /absolute/path/to/sing-box
bash -c 'source ./proxyall; pa_validate_bundle "$PWD"'
```

轉發選單入口：`sb.sh` 的 `_advanced_features` → `advanced_relay.sh`；中轉刪除／改端口／清空為子選單 5／6／7，端口轉發為子選單 8。
