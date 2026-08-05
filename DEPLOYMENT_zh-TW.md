# Nextcloud 部署指南

本指南提供使用 Docker 或 Podman Compose 部署 Nextcloud + PostgreSQL（pgvector）的逐步說明。

---

## 目錄

1. [系統需求](#1-系統需求)
2. [安裝容器執行環境](#2-安裝容器執行環境)
3. [複製儲存庫](#3-複製儲存庫)
4. [設定環境變數](#4-設定環境變數)
5. [準備資料目錄](#5-準備資料目錄)
6. [啟動服務](#6-啟動服務)
7. [驗證部署](#7-驗證部署)
8. [初始 Nextcloud 設定](#8-初始-nextcloud-設定)
9. [設定 Cloudflare Tunnel](#9-設定-cloudflare-tunnel)
10. [啟用 AI 功能（pgvector）](#10-啟用-ai-功能pgvector)
11. [設定自動備份](#11-設定自動備份)
12. [維護操作](#12-維護操作)
13. [升級](#13-升級)
14. [解除安裝/清理](#14-解除安裝清理)

---

## 1. 系統需求

### 硬體

| 資源 | 最低需求 | 建議配置 |
|------|----------|----------|
| 記憶體 | 4 GB | 8-16 GB |
| CPU | 2 核心 | 4+ 核心 |
| 儲存空間 | 20 GB | 100+ GB（依使用者資料量而定） |
| 網路 | 穩定的網路連線 | Gigabit 區域網路 |

### 軟體

| 軟體 | 版本 | 檢查指令 |
|------|------|----------|
| Docker | 20.10+ | `docker --version` |
| Docker Compose | 2.0+ | `docker compose version` |
| **或** Podman | 4.0+ | `podman --version` |
| Podman Compose | 1.0+ | `podman-compose --version` |
| Git | 2.0+ | `git --version` |

---

## 2. 安裝容器執行環境

### 選項 A：Docker（建議初學者使用）

**Ubuntu/Debian：**

```bash
# 更新系統
sudo apt update && sudo apt upgrade -y

# 安裝 Docker
curl -fsSL https://get.docker.com | sh

# 將使用者加入 docker 群組（避免使用 sudo）
sudo usermod -aG docker $USER

# 登出再登入，然後驗證
docker --version
docker compose version
```

**Fedora/RHEL：**

```bash
sudo dnf install docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### 選項 B：Podman（無 root 權限，更安全）

**Ubuntu/Debian：**

```bash
sudo apt update
sudo apt install -y podman podman-compose
podman --version
```

**Fedora/RHEL：**

```bash
sudo dnf install podman podman-compose
```

> **注意：** 本指南中請將 `docker compose` 替換為 `podman-compose`（如使用 Podman），將 `docker exec` 替換為 `podman exec`。

---

## 3. 複製儲存庫

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud.git
cd Woow_podman_nextcloud
```

驗證目錄結構：

```bash
ls -la
# 預期檔案：docker-compose.yml  .env.example  scripts/  README.md  ...
```

---

## 4. 設定環境變數

### 4.1 建立 .env 檔案

```bash
cp .env.example .env
```

### 4.2 產生安全密碼

```bash
# 產生隨機密碼
echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
echo "NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -base64 24)"
```

### 4.3 編輯設定

```bash
nano .env
```

**必須修改的項目：**

```env
# 資料庫 - 使用強密碼
POSTGRES_PASSWORD=<您產生的密碼>

# 管理員 - 使用強密碼
NEXTCLOUD_ADMIN_PASSWORD=<您產生的密碼>

# 加入所有您要用來存取 Nextcloud 的網域/IP
NEXTCLOUD_TRUSTED_DOMAINS=localhost 192.168.1.100 cloud.your-domain.com
```

**選用：自訂連接埠（預設為 18080）：**

```env
NEXTCLOUD_PORT=18080
```

### 4.4 驗證設定

```bash
# 檢查 .env 中是否還有預設密碼
grep "CHANGE_ME" .env
# 如果您已更新所有密碼，此指令不應有任何輸出
```

---

## 5. 準備資料目錄

```bash
mkdir -p data/{nextcloud/html,nextcloud/data,postgres,redis}
```

驗證：

```bash
tree data/ -L 2
# 預期結構：
# data/
# ├── nextcloud/
# │   ├── data/
# │   └── html/
# ├── postgres/
# └── redis/
```

> **注意：** 如果未安裝 `tree`，請使用 `ls -R data/` 替代。

---

## 6. 啟動服務

### 6.1 啟動所有服務

```bash
# Docker
docker compose up -d

# Podman
podman-compose up -d
```

### 6.2 監控啟動進度

```bash
# 查看容器狀態（重複執行直到全部顯示 "healthy"）
docker compose ps

# 查看即時日誌
docker compose logs -f
```

**預期啟動順序：**
1. `nextcloud-db`（PostgreSQL）啟動並變為健康狀態
2. `nextcloud-redis` 啟動並變為健康狀態
3. `nextcloud-app` 在 db 和 redis 健康後啟動
4. `nextcloud-cron` 在 nextcloud-app 之後啟動

### 6.3 首次初始化

首次啟動時，Nextcloud 會：
- 初始化資料庫架構
- 建立管理員帳號
- 安裝預設應用程式

這可能需要 1-3 分鐘。使用以下指令監控：

```bash
docker compose logs -f nextcloud
```

等待直到看到：`AH00094: Command line: 'apache2 -D FOREGROUND'`

---

## 7. 驗證部署

### 7.1 檢查服務健康狀態

```bash
docker compose ps
```

預期輸出：
```
NAME               STATUS                    PORTS
nextcloud-app      Up (healthy)              0.0.0.0:18080->80/tcp
nextcloud-cron     Up
nextcloud-db       Up (healthy)
nextcloud-redis    Up (healthy)
```

### 7.2 測試網頁存取

```bash
# 從伺服器本機
curl -I http://localhost:18080
# 預期：HTTP/1.1 302 Found（重導向至登入頁面）
```

### 7.3 測試資料庫連線

```bash
docker exec nextcloud-db pg_isready -U nextcloud
# 預期：/var/run/postgresql:5432 - accepting connections
```

### 7.4 測試 Redis

```bash
docker exec nextcloud-redis redis-cli ping
# 預期：PONG
```

---

## 8. 初始 Nextcloud 設定

### 8.1 存取網頁介面

在瀏覽器開啟：**http://\<伺服器IP\>:18080**

使用以下帳號登入：
- 使用者名稱：`.env` 中 `NEXTCLOUD_ADMIN_USER` 的值（預設：`admin`）
- 密碼：`.env` 中 `NEXTCLOUD_ADMIN_PASSWORD` 的值

### 8.2 設定背景任務

1. 前往 **設定**（點擊右上角頭像）> **基本設定**
2. 在 **背景任務** 中選擇 **Cron**
3. cron 容器會自動處理

### 8.3 驗證 Redis 快取

1. 前往 **設定** > **總覽**
2. 確認「記憶體快取」顯示已設定
3. 或透過指令驗證：

```bash
docker exec -u www-data nextcloud-app php occ config:system:get memcache.distributed
# 預期：\OC\Memcache\Redis
```

### 8.4 安全強化

1. 前往 **設定** > **總覽**，處理所有安全警告
2. 為管理員帳號啟用**雙重驗證**：
   - 前往 **設定** > **安全** > **雙重驗證**
   - 安裝並設定 TOTP 應用程式

---

## 9. 設定 Cloudflare Tunnel

### 9.1 前置需求

- Cloudflare 帳號
- 已將網域 DNS 指向 Cloudflare
- 伺服器上已安裝 `cloudflared`

### 9.2 安裝 cloudflared

```bash
# Debian/Ubuntu
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install cloudflared
```

### 9.3 建立並設定 Tunnel

```bash
# 登入 Cloudflare
cloudflared tunnel login

# 建立 tunnel
cloudflared tunnel create nextcloud

# 設定 tunnel
cat > ~/.cloudflared/config.yml << EOF
tunnel: <TUNNEL-ID>
credentials-file: /home/$USER/.cloudflared/<TUNNEL-ID>.json

ingress:
  - hostname: cloud.your-domain.com
    service: http://localhost:18080
  - service: http_status:404
EOF

# 設定 DNS
cloudflared tunnel route dns nextcloud cloud.your-domain.com
```

### 9.4 更新 Nextcloud 設定

更新 `.env`：

```env
NEXTCLOUD_TRUSTED_DOMAINS=localhost cloud.your-domain.com
OVERWRITEPROTOCOL=https
OVERWRITECLIURL=https://cloud.your-domain.com
TRUSTED_PROXIES=172.16.0.0/12
```

重新啟動 Nextcloud：

```bash
docker compose restart nextcloud
```

### 9.5 將 Tunnel 設為系統服務

```bash
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

---

## 10. 啟用 AI 功能（pgvector）

### 10.1 啟用 pgvector 擴充

```bash
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

驗證：

```bash
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

### 10.2 安裝 Recognize 應用程式

1. 以管理員身分登入 Nextcloud
2. 前往 **應用程式** > 搜尋 "**Recognize**"
3. 點擊 **安裝並啟用**
4. 前往 **設定** > **Recognize** 進行設定
5. 應用程式將使用 pgvector 進行高效的相似度搜尋

---

## 11. 設定自動備份

### 11.1 手動備份

```bash
./scripts/backup.sh
```

### 11.2 排程自動備份（cron）

```bash
# 編輯 crontab
crontab -e

# 加入每日凌晨 3:00 自動備份
0 3 * * * /path/to/Woow_podman_nextcloud/scripts/backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

### 11.3 備份輪替

保留最近的備份，刪除舊的：

```bash
# 保留最近 7 天的備份
find /path/to/backups/ -name "nextcloud_backup_*.tar.gz" -mtime +7 -delete
```

在 crontab 備份指令之後加入：

```bash
30 3 * * * find /path/to/Woow_podman_nextcloud/backups/ -name "nextcloud_backup_*.tar.gz" -mtime +7 -delete
```

---

## 12. 維護操作

### 12.1 啟用/停用維護模式

```bash
# 啟用（阻止使用者存取）
docker exec -u www-data nextcloud-app php occ maintenance:mode --on

# 停用
docker exec -u www-data nextcloud-app php occ maintenance:mode --off
```

### 12.2 檔案掃描

手動新增/移動檔案後：

```bash
docker exec -u www-data nextcloud-app php occ files:scan --all
```

### 12.3 修復權限

```bash
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/data
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/config
```

### 12.4 檢查系統狀態

```bash
docker exec -u www-data nextcloud-app php occ status
docker exec -u www-data nextcloud-app php occ config:system:get version
```

### 12.5 資料庫維護

```bash
# 新增遺漏的資料庫索引
docker exec -u www-data nextcloud-app php occ db:add-missing-indices

# 轉換 filecache bigint 欄位
docker exec -u www-data nextcloud-app php occ db:convert-filecache-bigint
```

---

## 13. 升級

### 13.1 一般升級

```bash
# 1. 先備份
./scripts/backup.sh

# 2. 拉取最新映像檔
docker compose pull

# 3. 重建容器
docker compose up -d

# 4. 驗證
docker exec -u www-data nextcloud-app php occ status
docker exec -u www-data nextcloud-app php occ app:update --all
```

### 13.2 主要版本升級

主要版本升級（例如 NC 28 -> 29）：

```bash
# 1. 備份
./scripts/backup.sh

# 2. 啟用維護模式
docker exec -u www-data nextcloud-app php occ maintenance:mode --on

# 3. 拉取並重建
docker compose pull
docker compose up -d

# 4. 執行升級
docker exec -u www-data nextcloud-app php occ upgrade

# 5. 停用維護模式
docker exec -u www-data nextcloud-app php occ maintenance:mode --off

# 6. 更新應用程式
docker exec -u www-data nextcloud-app php occ app:update --all
```

---

## 14. 解除安裝/清理

### 14.1 停止並移除容器

```bash
docker compose down
```

### 14.2 移除資料（不可復原）

```bash
# 警告：此操作將永久刪除所有資料
sudo rm -rf data/
```

### 14.3 移除映像檔

```bash
docker rmi nextcloud:stable pgvector/pgvector:pg16 redis:alpine
```

### 14.4 移除磁碟區和網路

```bash
docker network rm nextcloud-network 2>/dev/null || true
```
