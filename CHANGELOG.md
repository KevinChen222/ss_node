# 修改記錄

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
