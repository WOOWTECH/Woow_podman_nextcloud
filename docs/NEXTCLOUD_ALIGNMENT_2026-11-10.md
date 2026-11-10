# Nextcloud Podman 建置與來源對照（2026-11-10）

## 範圍與來源

本次建立**全新空白實例**，沒有還原舊 Nextcloud 資料。實體位於 `192.168.2.46:18081`；四個資料目錄位於 `~/.local/share/nextcloud-office/`。舊環境檔已另存，舊備份未用於新實例。

| 來源 | 版本／可查證內容 | 取得狀態 |
|---|---|---|
| [HA add-on](https://github.com/WOOWTECH/Woow_ha_nextcloud/tree/v0.2.3/woow-nextcloud-office) | `v0.2.3` 宣告 Nextcloud 35.0.1；目前 `main` 為 `cbed75394a41c86376164d59e3ad49ad42b2ccdf`，有未發布 runtime 研究內容 | 已讀設定、Dockerfile、初始化腳本與 QA；沒有把原始碼直接當成已發布映像的運行證據 |
| PaaS Gitea `woow-paas/woow-paas-charts` 的現行 `main` | 預期來源 `charts/nextcloud` 與平台 template | `git-prod.woowtech.io` 導向 Cloudflare Access；尚未取得現行 chart、values 與部署設定，因此**不能宣稱已與現行 PaaS 完全對齊** |
| [K3s 公開鏡像](https://github.com/WOOWTECH/Woow_k3s_nextcloud/tree/main) | `0116d18a4e8b26250293bd4bc9ea21f8a7bdca7b`（2026-09-13） | 已讀 `values.yaml`／templates，僅作為較舊的 PaaS 架構參考，不能代替 Gitea 現行 `main` |

## 能力對照

| 能力 | HA add-on／已知 K3s 來源 | Podman 實作與驗收 |
|---|---|---|
| Nextcloud | HA 0.2.3 宣告 35.0.1；K3s 公開鏡像用浮動 `stable` | 固定 Nextcloud 35.0.1，`status.php` 與 `occ status` 通過；Podman 官方基底現為 PHP 8.5，HA 原始碼使用 PHP 8.4 |
| PostgreSQL 與向量擴充 | HA PostgreSQL 16；K3s PostgreSQL 16 + pgvector | PostgreSQL 16 + pgvector 0.8.6；資料在獨立本機目錄，已建立 `vector` extension |
| Redis 與背景工作 | HA Redis；K3s Redis + Cron sidecar | Redis AOF、Nextcloud 快取與鎖、每五分鐘的 systemd Cron；實際執行 `cron.php` 通過 |
| Office 編輯 | HA 內建 CODE、richdocuments、同源路由 | Collabora CODE 26.04.4.2、實測已安裝 richdocuments 12.0.1、同源 `/hosting`、`/browser`、`/cool`。無頭 Chromium 完成 ODT 開啟、輸入、儲存，WebDAV 讀回修改內容；備份還原後再驗證通過。文件暫存使用 2 GiB tmpfs，避開根分割區低於 [CODE 的 5% 可用空間門檻](https://github.com/CollaboraOnline/online.mirror/blob/main/common/FileUtil.hpp#L146-L155) 時的載入失敗。richdocuments 的新安裝版本取決於 Nextcloud App Store 當時供應的相容版本 |
| Office 管理介面 | HA 可啟用管理介面，並能選擇停用 Collabora | Podman 使用獨立 Secret；未認證 HTTP 401、以 Secret 認證 HTTP 200；`/collabora-admin/` 轉至管理頁。目前 Podman 固定啟用 Office，尚無停用開關 |
| 媒體與外部儲存工具 | HA 映像安裝 ImageMagick、ffmpeg、smbclient、davfs2 | Podman 以固定 Nextcloud 基底建置擴充映像，含 PHP imagick 與相應命令列工具。實際 SMB／DAV 伺服器掛載尚無測試目標；rootless Podman 對 `mount.davfs` 的核心掛載能力不同於 HA add-on 的 `SYS_ADMIN` 權限 |
| 郵件與 PHP 上限 | HA 有 SMTP 設定項，PHP 記憶體 1024M、上傳 16G | Podman 提供官方映像的 `SMTP_*`／`MAIL_*` 設定及相同 PHP 上限；本實例沒有 SMTP 帳號，尚未實際寄信；16G 上傳仍須有足夠磁碟容量 |
| 公開網址／信任代理 | HA 可設定 public URL、trusted domains/proxies | `NEXTCLOUD_PUBLIC_URL`、`COLLABORA_SERVER_NAME`、`COLLABORA_SSL_TERMINATION`、`NEXTCLOUD_TRUSTED_DOMAINS`、`TRUSTED_PROXIES` 可設；目前實測 LAN HTTP，HTTPS reverse proxy 的設定已做靜態驗證，尚未用正式域名實測 |
| 使用者資料與應用程式 | HA 將資料與 `custom_apps` 持久化；K3s 用 PVC | Podman 將 html、data、PostgreSQL、Redis 各自持久化；richdocuments 在 html 的 `custom_apps`，重啟和還原後仍啟用 |
| 密鑰／備份／升級 | HA cold backup；K3s PVC／Secret 保留 | Podman Secrets、線上備份、冷備份、SHA256 驗證、同版映像切換與還原實測通過；升級閘限制逐一跨大版本 |
| HA ingress／側欄 | HA 專屬 Supervisor 功能 | Podman 以獨立入口提供相同 Nextcloud／Office 服務；不安裝 Supervisor ingress |

## 實測紀錄

- `tests/dryrun.sh`：三種設定變體均通過；Quadlet 4.9.3 驗證通過。
- `scripts/install.sh`／`tests/smoke.sh`：全部服務、Nextcloud 版本、PostgreSQL／Redis、Cron、Office discovery、監聽埠通過。
- `tests/webdav.py`：上傳、讀取、PROPFIND、移動及清理通過。
- OCS 分享 API：建立公開唯讀分享，匿名開啟 HTTP 200，並刪除分享與測試檔。
- `tests/office_browser.py`：管理員瀏覽器登入，開啟測試 ODT、修改與儲存，透過 WebDAV 讀回修改後文字；測試檔已清理。切換新映像後曾因根分割區空間低於 CODE 門檻而失敗；將 CODE 文件暫存掛到獨立 tmpfs 後，使用公開 LAN 網址再次通過。用 `127.0.0.1` 開啟時，瀏覽器因框架來源不同回報 `net::ERR_BLOCKED_BY_RESPONSE`；測試現預設從本機設定檔讀取標準公開網址。
- `scripts/backup.sh`：`config.tgz`、`data.tgz`、資料庫 dump、角色、三個 Secrets、Gateway 設定、unit 與 SHA256SUMS 均存在，SHA256 校驗通過；最新備份位於 `~/backups/nextcloud/acceptance-final-20261110`。
- `scripts/restore.sh`：備份校驗、資料庫、角色、Secrets、設定與使用者資料還原，`maintenance:data-fingerprint` 與 smoke 通過；還原後再次通過 Office 編輯儲存。
- `scripts/upgrade.sh`：同版擴充映像 `35.0.1-office2` 的切換與冷備份通過；最新冷備份為 `~/backups/nextcloud/upgrade-20261110-224923`。曾因啟動瞬間 gateway 暫時 `inactive` 觸發一次自動回滾；健康檢查已改為等待就緒，重新切換通過。
- `tests/version-check.sh` 6 項、`tests/rollback-model.sh` 14 項、`tests/lock-release.sh` 5 項，以及 Bash ShellCheck、Python 語法、三種 Quadlet dry-run 全部通過。

## 待核對

1. 取得 PaaS Gitea `main` 的 `charts/nextcloud`、`values.yaml`、平台 template 與實際引用版本，逐項比對現行功能；目前公開 K3s 鏡像不能取代這一步。
2. 若要正式使用 HTTPS 網域，提供域名及 TLS reverse proxy 入口後，實測 Office WOPI、WebDAV 與分享連結在該入口的端到端行為。
3. 如需 SMTP、SMB 或 DAV 實際服務驗收，需提供對應測試伺服器與授權；目前僅確認程式能力與設定入口。HA 的 `davfs2` 核心掛載權限與 rootless Podman 不等同。
4. 主機根分割區在本次建置後只剩約 3–4 GiB 可用，接近滿載。CODE 的 2 GiB tmpfs 讓文件編輯可用，但 Nextcloud 持久檔案仍在根分割區；正式存放檔案前必須擴充磁碟或清出足夠空間。tmpfs 的同時編輯容量尚未做負載測試。
5. HA add-on 具 `SYS_ADMIN` 權限；Podman 為 rootless，CODE 啟動參數關閉 mount jail tree、內部 seccomp 與 capability 檢查。Office 功能已實測，但隔離方式與 HA 原始碼不相同；亦尚未提供 HA 的 Office 停用開關。
