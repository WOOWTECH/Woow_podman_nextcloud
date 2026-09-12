# Nextcloud on rootless Podman（Quadlet + systemd）

以 **rootless Podman Quadlet unit** 部署 [Nextcloud](https://nextcloud.com/)，搭配 PostgreSQL 16
（pgvector）與 Redis，全部交由使用者的 systemd 管理。unit 就是部署本身：開機自動啟動（需要
linger）、容器當掉時自動重啟、背景工作由 timer 執行，所有版本都釘選在這個 repo 裡。

[English version](README.md)

## 架構

```
        systemctl --user start|stop|restart nextcloud.target
                              │
   ┌──────────────────────────┼───────────────────────────┐
   │                          │                           │
nextcloud-db.service   nextcloud-redis.service   nextcloud-app.service
pgvector/pgvector      redis:8.10.1-alpine       nextcloud:34.0.3-apache
 :0.8.6-pg16                 │                           │
   │ HOST_POSTGRES_DIR       │ HOST_REDIS_DIR            │ HOST_HTML_DIR
   │                         │                           │ HOST_DATA_DIR
   └──────────── network nextcloud-network ──────────────┘
                                                          │
                              PublishPort HOST_BIND:HOST_PORT -> 80
                              （預設 127.0.0.1:18080；對外由 Cloudflare
                                Tunnel 或 NPM 提供）

        nextcloud-cron.timer ──每 5 分鐘──> nextcloud-cron.service
              podman exec -u www-data nextcloud-app php -f cron.php
```

| 檔案 | unit | 內容 |
|---|---|---|
| `quadlet/nextcloud.network` | `nextcloud-network.service` | bridge 網路 `nextcloud-network` |
| `quadlet/nextcloud-db.container` | `nextcloud-db.service` | PostgreSQL 16 + pgvector |
| `quadlet/nextcloud-redis.container` | `nextcloud-redis.service` | 分散式快取與檔案鎖 |
| `quadlet/nextcloud-app.container` | `nextcloud-app.service` | Nextcloud（Apache，容器內 80 埠） |
| `systemd/nextcloud-cron.service` | `nextcloud-cron.service` | 執行一次 `cron.php` |
| `systemd/nextcloud-cron.timer` | `nextcloud-cron.timer` | 每 5 分鐘 |
| `systemd/nextcloud.target` | `nextcloud.target` | 一次操作整個堆疊 |

安裝位置：`~/.config/containers/systemd/`（Quadlet）、`~/.config/systemd/user/`（target、cron
service 與 timer）、`~/.config/nextcloud/nextcloud.env`（設定，權限 0600）。密碼一律使用
podman secret，不會出現在環境檔裡。

**不再有 cron 容器。** 舊的 `nextcloud-cron` 容器跑的是 busybox crond；改成 `Type=oneshot`
service 加 timer 之後，執行不會重疊、可以用 `systemctl --user list-timers` 看到下一次時間，
而且 app 停著的時候是「跳過」而不是「失敗」。

**資料庫與 Redis 位於私有 bridge 網路**，不再掛在主機的 loopback 上。先前的手動部署所有容器
都用 `--network host`，而 `pg_hba.conf` 對 `127.0.0.1` 是 `trust`，也就是說主機上任何行程、
以及任何其他 host network 容器，都能以超級使用者身分免密碼連進 PostgreSQL，Redis 也沒有密碼。

## 系統需求

- Ubuntu 24.04 或同級系統，**podman >= 4.9.3** rootless，systemd 255 使用者 unit
- 服務帳號啟用 linger（`sudo loginctl enable-linger $USER`），登出後堆疊才會繼續執行
- 映像檔約 1.3 GB，另外還要放 html 目錄（約 900 MB）、資料庫與使用者檔案
- PostgreSQL 目錄必須放在**本機磁碟**（不可用 NFS 或 SMB），`install.sh` 會檢查

```bash
podman --version && systemctl --user show-environment >/dev/null && echo "user manager ok"
```

## 安裝

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud ~/woow-quadlet/Woow_podman_nextcloud
cd ~/woow-quadlet/Woow_podman_nextcloud
tests/dryrun.sh                               # 選用：驗證所有 unit，不會建立任何東西
scripts/install.sh                            # 第一次執行：建立設定檔後停下
$EDITOR ~/.config/nextcloud/nextcloud.env     # 四個 HOST_*_DIR 路徑與信任網域
scripts/install.sh                            # 安裝、啟動並執行 smoke 測試
```

第一次安裝會等 entrypoint 解開 Nextcloud，接著設定 cron 背景工作模式、建立 `vector` 擴充、
補上缺少的資料庫索引，並印出讀取管理者密碼的方式：

```bash
podman secret inspect --showsecret nextcloud-admin-password
```

接著打開 `http://127.0.0.1:18080/`（或你設定的 `HOST_BIND:HOST_PORT`）。
**你用來連線的每一個名稱或位址都必須列在 `NEXTCLOUD_TRUSTED_DOMAINS`**，否則 Nextcloud 會
回應「透過不信任的網域存取」。

其他選項：`--db-password-file F` 與 `--admin-password-file F`（僅第一次安裝）、`--no-start`、
`--no-smoke`、`--smoke-timeout S`、`--dry-run`（只算出結果並驗證）。

## 設定

`~/.config/nextcloud/nextcloud.env`，權限 0600，只能寫 `KEY=value`：不要加引號、不要 `export`、
也不要在值後面接 `# 註解`。`HOST_*` 會在安裝時寫進 unit 檔（決策 D2），其餘的鍵會傳給 app
容器，因此
[映像檔支援的環境變數](https://github.com/nextcloud/docker#environment-variables)都能用。
改完之後重新執行 `scripts/install.sh`，它只會重啟真的有變動的 unit。

| 鍵 | 預設值 | 意義 |
|---|---|---|
| `HOST_BIND` | `127.0.0.1` | 發布位址。`0.0.0.0` 代表對所有介面開放 |
| `HOST_PORT` | `18080` | 發布的埠（容器內 Apache 聽 80） |
| `HOST_HTML_DIR` | `%h/.local/share/nextcloud/html` | `/var/www/html`：程式碼、app 與 `config/config.php` |
| `HOST_DATA_DIR` | `%h/.local/share/nextcloud/data` | `/var/www/html/data`：使用者檔案，會一直長大的就是它 |
| `HOST_POSTGRES_DIR` | `%h/.local/share/nextcloud/postgres` | PGDATA，只能放本機磁碟 |
| `HOST_REDIS_DIR` | `%h/.local/share/nextcloud/redis` | Redis append-only 檔案 |
| `NEXTCLOUD_ADMIN_USER` | `admin` | 僅第一次安裝時使用 |
| `NEXTCLOUD_TRUSTED_DOMAINS` | `localhost 127.0.0.1` | 以空白分隔，第一次啟動時寫入 |
| `OVERWRITEPROTOCOL` | 空白 | 前面有 TLS 代理或 tunnel 但不送 `X-Forwarded-Proto` 時設為 `https` |
| `OVERWRITECLIURL`、`TRUSTED_PROXIES` | 空白 | 由映像檔的 `reverse-proxy.config.php` 讀取 |
| `PHP_MEMORY_LIMIT`、`PHP_UPLOAD_LIMIT` | `512M` | PHP 限制 |

每個 `HOST_*_DIR` 都是絕對路徑，或以 `%h/` 開頭代表家目錄。已經有 Nextcloud 資料的路徑會
原地沿用，不會複製也不會搬移（決策 D9）。

**絕對不要加開頭是 `NC_` 的鍵。** Nextcloud 會把 `NC_<key>` 當成 `config.php` 的覆寫；
`install.sh` 發現就會拒絕。unit 自己會設定 `NC_dbhost` 與 `REDIS_HOST`，這正是為什麼
`config.php` 仍寫著 `dbhost=127.0.0.1` 的既有站台，不必改設定就能在 bridge 上連到資料庫，
回滾時同樣不必改。

`POSTGRES_HOST`、`POSTGRES_DB`、`POSTGRES_USER` 與 `REDIS_HOST` 固定寫在 unit 裡
（`--env` 優先於 `--env-file`），不會和資料庫 unit 不一致。

**Secret**（podman secret，第一次安裝時建立，不會被印出來）：

| Secret | 用途 |
|---|---|
| `nextcloud-db-password` | `POSTGRES_PASSWORD`：initdb，以及 Nextcloud 第一次安裝 |
| `nextcloud-admin-password` | `NEXTCLOUD_ADMIN_PASSWORD`：僅安裝時使用，之後會被忽略 |

Nextcloud 安裝完成後，是以 `config.php` 裡的 `dbpassword` 用 `oc_admin` 這個角色連線；那份
設定屬於 html 目錄裡的 Nextcloud 自有狀態。

## 日常操作

```bash
systemctl --user status nextcloud-app.service       # 單一 unit
systemctl --user restart nextcloud.target           # 整個堆疊
journalctl --user -u nextcloud-app.service -f       # 日誌（LogDriver=journald）
systemctl --user list-timers nextcloud-cron.timer   # 下一次 cron.php
systemctl --user start nextcloud-cron.service       # 立刻執行背景工作
tests/smoke.sh                                      # 健康檢查
tests/smoke.sh --public-url https://cloud.example.com/
```

`occ` 不允許用 root 執行，一律以 `www-data` 身分執行：

```bash
occ() { podman exec -u www-data nextcloud-app php /var/www/html/occ "$@"; }

occ status
occ user:list
occ files:scan --all
occ app:update --all
occ config:system:set trusted_domains 2 --value=cloud.example.com
```

資料庫：

```bash
podman exec -it nextcloud-db psql -U nextcloud -d nextcloud
podman exec nextcloud-db psql -U nextcloud -d nextcloud -c "SELECT pg_size_pretty(pg_database_size('nextcloud'));"
```

### AI 相片標記（Recognize）

第一次安裝時 `install.sh` 會建立 `vector` 擴充，因此可以直接在 **App** 裡安裝
[Recognize](https://apps.nextcloud.com/apps/recognize)，並到 **設定 → Recognize** 設定。
既有站台請先確認：

```bash
podman exec nextcloud-db psql -U nextcloud -d nextcloud -c "SELECT extname, extversion FROM pg_extension;"
```

### 搭配 Cloudflare Tunnel 或 Nginx Proxy Manager

`HOST_BIND` 維持 `127.0.0.1`，把 tunnel 或代理指向 `http://localhost:18080`，並在
`~/.config/nextcloud/nextcloud.env` 設定：

```ini
OVERWRITEPROTOCOL=https
OVERWRITECLIURL=https://cloud.example.com
TRUSTED_PROXIES=127.0.0.1
NEXTCLOUD_TRUSTED_DOMAINS=localhost cloud.example.com
```

然後再執行一次 `scripts/install.sh`。沒有設定 `TRUSTED_PROXIES` 的話，Nextcloud 會把 bridge
的 gateway 當成所有請求的來源，暴力破解防護會變成全體共用，日誌也看不到真正的來源 IP。

tunnel 本身由
[Woow_cloudflare_tunnel_webgui](https://github.com/WOOWTECH/Woow_cloudflare_tunnel_webgui)
部署，這個 repo 不會安裝 `cloudflared`。

## 升級

repo 就是版本的唯一真相：修改 `quadlet/nextcloud-app.container` 的 `Image=` 並 commit，然後：

```bash
git pull
scripts/upgrade.sh            # --repair 會額外執行 maintenance:repair --include-expensive
```

**一次只能升一個大版本。** Nextcloud 的 entrypoint 本來就會拒絕跳版，但那時舊容器已經消失了，
所以 `upgrade.sh` 會先比對已安裝的 `version.php` 與映像檔的 `NEXTCLOUD_VERSION`，在任何東西
停止之前就拒絕。降版與 PostgreSQL 大版本變更同樣會被擋下。

接著它會做一份冷備份（dump、roles、`config/`、html 目錄與資料庫目錄），安裝新的 unit，然後
輪詢 `status.php` 最多 30 分鐘：`--sdnotify=conmon` 會在 entrypoint 還在 rsync 新版本、還在跑
`occ upgrade` 的時候就把 unit 標記為 active。完成後會補索引、補欄位、補主鍵並更新 app。
**失敗會自動回滾**——Nextcloud 無法降版，所以 html 目錄與資料庫必須一起回去。

不要釘 `nextcloud:stable`，那個 tag 會移動，容器一旦啟動在比資料還新的版本上就會拒絕執行。

**PostgreSQL 大版本升級**（16 → 17）是另一件工作：`scripts/backup.sh --cold`、改資料庫映像檔、
把 `HOST_POSTGRES_DIR` 移開、`scripts/install.sh`，最後 `scripts/restore.sh`。

## 備份與還原

```bash
scripts/backup.sh                    # 維護模式、DB dump + roles、config、使用者檔案
scripts/backup.sh --no-data          # 不含使用者檔案
scripts/backup.sh --cold             # 另外停下堆疊，完整複製 html 與 PGDATA
scripts/restore.sh ~/backups/nextcloud/<timestamp> [--with-html] [--yes]
```

備份目錄權限 0700，內含 `SHA256SUMS`，`restore.sh` 會驗證。裡面有資料庫密碼與管理者密碼：
請另外保存在這台主機之外，並比照密碼本身處理。`roles.sql` 會跟著 dump 一起備份，因為
`config.php` 是以 `oc_admin` 連線的，而 `pg_dump` 不會帶角色。

備份期間會開啟維護模式，並由 trap 在結束時關閉，**失敗時也一樣**——不像舊版腳本把失敗的
`occ maintenance:mode --on` 用 `|| true` 吞掉，結果備份的是一個還在服務中的站台。

每天自動備份（以服務帳號執行）：

```bash
systemd-run --user --on-calendar='*-*-* 03:30:00' --unit=nextcloud-backup \
  ~/woow-quadlet/Woow_podman_nextcloud/scripts/backup.sh
```

## 解除安裝

```bash
scripts/uninstall.sh                 # 停止並移除 unit 與 timer，資料全部保留
scripts/uninstall.sh --purge --yes   # 另外刪除網路與兩個 secret
```

`--purge` 會先把兩個 secret 與設定檔匯出到 `~/backups/nextcloud/purge-<timestamp>/`，而且
**絕對不會**刪掉四個資料目錄：它只會印出對應的 `podman unshare rm -rf` 指令，避免打錯路徑
就毀掉使用者檔案。

## 從既有的 compose 或手動部署遷移

`scripts/migrate-legacy.sh` 會原地沿用 html、data、PostgreSQL 與 Redis 目錄——路徑是從
`podman inspect` 讀出來的，不是用猜的，也完全不複製——並保留舊容器與舊 unit 供回滾。
停機時間是 8–12 分鐘的維護模式，請預留 30 分鐘。

```bash
# 1. 舊堆疊照常執行時先檢查與準備（不停機）
scripts/migrate-legacy.sh --legacy-dir ~/podman/nextcloud --dry-run
scripts/migrate-legacy.sh --legacy-dir ~/podman/nextcloud --bind 0.0.0.0 --prepare-only

# 2. 正式切換（開始停機）：維護模式、dump、停止、冷備份、改名、安裝、smoke
scripts/migrate-legacy.sh --legacy-dir ~/podman/nextcloud --bind 0.0.0.0 --yes

# 3. 有問題時（約 3 分鐘；兩套堆疊共用同樣的目錄）
scripts/migrate-legacy.sh --rollback --yes
```

**要先確認的是資料庫密碼。** host network 部署是透過 `127.0.0.1` 連 PostgreSQL，而
`pg_hba.conf` 對它是 `trust`，所以 `config.php` 裡給 `oc_admin` 的那組密碼從來沒被真正驗證過；
換到 bridge 之後它就必須能用。步驟 1 會拿它去比對 `pg_authid` 裡的 SCRAM verifier——只會印出
`match=true` 或 `match=false`，絕不會印出密碼——不符就拒絕切換。`--fix-db-password` 會把角色的
密碼設成 `config.php` 已經在用的那一組，對舊堆疊而言完全沒有影響。

這次遷移刻意改變的其他事情：host network 改成 bridge（因此 `apache-ports.conf` 與
`apache-site.conf` 覆寫檔功成身退，Apache 在容器內聽 80）、cron 容器改成 timer、浮動 tag
`stable`、`pg16`、`alpine` 改成它們今天實際指到的確切版本，密碼也從舊的 `.env`
（連資料庫容器都拿得到整份，包括管理者密碼）搬進 podman secret。

切換過程會先保存 `config.php`：新堆疊第一次寫設定時會把 `redis.host=nextcloud-redis` 寫進去，
`--rollback` 會把保存的那份放回去。

**觀察期結束後**（兩週，中間至少重開機一次）：

```bash
podman rm nextcloud-app-legacy-YYYYMMDD nextcloud-cron-legacy-YYYYMMDD \
          nextcloud-db-legacy-YYYYMMDD nextcloud-redis-legacy-YYYYMMDD
rm ~/.config/systemd/user/podman-nextcloud.service ~/.local/bin/start-migrated-nextcloud
systemctl --user daemon-reload
podman untag docker.io/library/nextcloud:stable docker.io/pgvector/pgvector:pg16 docker.io/library/redis:alpine
occ config:system:set dbhost --value=nextcloud-db     # 讓 config.php 說的是實話
occ config:system:get trusted_domains                 # 依索引刪掉已經沒用的項目
```

## 疑難排解

| 症狀 | 原因與處理 |
|---|---|
| `Unit nextcloud-app.service not found` | 產生器拒絕了某個檔案。執行 `tests/dryrun.sh`，再 `systemctl --user daemon-reload` |
| 安裝被拒：*legacy container* | 有非 Quadlet 容器佔用了名稱。Quadlet 的 `--replace` 會直接刪掉它：依訊息提示改名，或改用 `migrate-legacy.sh` |
| 「透過不信任的網域存取」 | 把名稱加進 `NEXTCLOUD_TRUSTED_DOMAINS` 再跑一次 `install.sh`，或 `occ config:system:set trusted_domains N --value=…` |
| `password authentication failed for user "oc_admin"` | 沿用的 `config.php` 密碼從未通過真正的驗證。`scripts/migrate-legacy.sh --fix-db-password` |
| `occ` 說 *Console has to be executed with the user that owns the file* | 你沒有加 `-u www-data` |
| 走 tunnel 但連結是 `http://` | 設定 `OVERWRITEPROTOCOL=https` 與 `TRUSTED_PROXIES` |
| 背景工作停住 | `systemctl --user list-timers nextcloud-cron.timer`，再看 `journalctl --user -u nextcloud-cron.service` |
| 重開機後堆疊沒有回來 | linger 沒開：`sudo loginctl enable-linger $USER` |
| `occ config:system:get dbhost` 顯示 `127.0.0.1` | 沿用的站台這樣是正常的：unit 的 `NC_dbhost` 會覆寫它，而且永遠不會寫回檔案 |

## Docker Compose

這個 repo 只提供 Quadlet。最後一個含 `docker-compose.yml` 的版本標記為
[`compose-final`](https://github.com/WOOWTECH/Woow_podman_nextcloud/tree/compose-final)：

```bash
git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_nextcloud
```

新的 Docker 部署請參考 Nextcloud 官方的
[docker 範例](https://github.com/nextcloud/docker#running-this-image-with-docker-compose)。

## 授權

MIT License，詳見 [LICENSE](LICENSE)。

## 其他部署方式

- **K3s / Kubernetes（Helm chart）** → [Woow_k3s_nextcloud](https://github.com/WOOWTECH/Woow_k3s_nextcloud)
- **Home Assistant add-on** → [Woow_ha_nextcloud](https://github.com/WOOWTECH/Woow_ha_nextcloud)
