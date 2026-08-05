# Nextcloud + PostgreSQL (pgvector) Docker/Podman 部署

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-3.8-blue)](docker-compose.yml)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-Stable-blue)](https://nextcloud.com/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16%20+%20pgvector-336791)](https://github.com/pgvector/pgvector)

[English](README.md) | [繁體中文](#概述)

---

## 概述

使用 Docker/Podman Compose 部署生產級 Nextcloud，搭配 PostgreSQL 16（啟用 pgvector）、Redis 快取及自動化背景任務。針對家用伺服器與自架環境優化，支援 Cloudflare Tunnel 安全外部存取。

## 功能特色

| 功能 | 說明 |
|------|------|
| **Nextcloud（穩定版）** | 最新穩定版本，搭配 Apache 網頁伺服器 |
| **PostgreSQL 16 + pgvector** | 向量資料庫，支援 AI 功能（Recognize 照片標記應用程式） |
| **Redis** | 記憶體快取與檔案鎖定，提升效能 |
| **Cron** | 獨立容器處理 Nextcloud 背景任務 |
| **備份/還原** | Shell 腳本完整備份與還原資料 |
| **Cloudflare Tunnel** | 預先設定安全外部存取，無需開啟連接埠 |
| **健康檢查** | 所有服務皆包含健康檢查，確保穩定性 |

## 架構圖

```
網際網路
   │
   ▼
Cloudflare Tunnel（SSL 終止）
   │
   ▼
主機:18080 ──► nextcloud-app（Apache + PHP）
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   nextcloud-db  nextcloud-   nextcloud-
   （PostgreSQL    redis        cron
    16+pgvector） （快取）     （背景任務）
        │
   nextcloud-network（bridge 網路）
```

### 服務詳細資訊

| 服務 | 映像檔 | 連接埠 | 用途 |
|------|--------|--------|------|
| `nextcloud` | `nextcloud:stable` | `18080:80` | 主要應用程式伺服器 |
| `db` | `pgvector/pgvector:pg16` | 內部 | 具向量支援的 PostgreSQL 資料庫 |
| `redis` | `redis:alpine` | 內部 | 快取與檔案鎖定 |
| `cron` | `nextcloud:stable` | 無 | 背景任務執行器 |

## 一鍵部署至 Portainer

使用 Portainer 的 Stack 功能，可透過 GitHub Repository 網址快速部署本專案。

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#一鍵部署至-portainer)

### 使用 Git Repository 部署（推薦）

1. 登入你的 Portainer 管理介面
2. 進入 **Stacks** → **Add stack**
3. 選擇 **Repository**
4. 填入以下資訊：

   | 欄位 | 值 |
   |------|-----|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_nextcloud` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. 點擊 **Deploy the stack**

### 使用 Web Editor 部署

1. 複製 `docker-compose.yml` 的 Raw URL：

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_nextcloud/main/docker-compose.yml
   ```

2. 登入 Portainer → **Stacks** → **Add stack** → **Web editor**
3. 使用 `curl` 或瀏覽器取得上述 URL 的內容，貼入編輯器
4. 設定環境變數（參考 `.env.example`）
5. 點擊 **Deploy the stack**

## 系統需求

- **Docker**（20.10+）或 **Podman**（4.0+）含 compose 外掛
- **4+ GB 記憶體**（建議 8-16 GB）
- **4+ CPU 核心**（建議）
- **20+ GB 磁碟空間**（依使用者資料量而定）
- （選用）**Cloudflare 帳號**用於 Tunnel 存取

## 快速開始

### 步驟 1：複製儲存庫

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud.git
cd Woow_podman_nextcloud
```

### 步驟 2：設定環境變數

```bash
cp .env.example .env
nano .env   # 或使用任何文字編輯器
```

**以下欄位必須修改：**

| 變數 | 說明 | 範例 |
|------|------|------|
| `POSTGRES_PASSWORD` | 設定強密碼 | `MyS3cur3DbP@ss!` |
| `NEXTCLOUD_ADMIN_PASSWORD` | 設定管理員強密碼 | `Adm1nP@ssw0rd!` |
| `NEXTCLOUD_TRUSTED_DOMAINS` | 您的網域（空格分隔） | `localhost cloud.example.com 192.168.1.100` |

### 步驟 3：建立資料目錄

```bash
mkdir -p data/{nextcloud/html,nextcloud/data,postgres,redis}
```

### 步驟 4：啟動所有服務

```bash
# 使用 Docker Compose
docker compose up -d

# 使用 Podman Compose
podman-compose up -d
```

### 步驟 5：確認服務運行狀態

```bash
# 檢查服務狀態
docker compose ps        # 或：podman-compose ps

# 預期結果：所有服務顯示 "Up" 或 "healthy"
```

### 步驟 6：啟用 pgvector 擴充

```bash
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

### 步驟 7：存取 Nextcloud

- **本機存取：** http://localhost:18080
- **透過 Cloudflare Tunnel：** https://your-domain.com

使用您在 `.env` 中設定的管理員帳號密碼登入。

## 安裝後設定

### 安裝 Recognize 應用程式（AI 照片標記）

1. 以管理員身分登入
2. 前往 **應用程式** > 搜尋 "**Recognize**"
3. 點擊 **安裝**
4. 在 **設定** > **Recognize** 中設定

### 設定背景任務為 Cron

1. 前往 **設定** > **基本設定**
2. 在 **背景任務** 中選擇 **Cron**

### Cloudflare Tunnel 設定

1. 在 [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) 儀表板建立 tunnel
2. 將公開主機名稱指向：`http://localhost:18080`
3. 在 `.env` 中將您的網域加入 `NEXTCLOUD_TRUSTED_DOMAINS`
4. 在 `.env` 中設定 `OVERWRITEPROTOCOL=https`
5. 重新啟動：`docker compose restart nextcloud`

## 備份與還原

### 建立備份

```bash
./scripts/backup.sh
# 輸出：backups/nextcloud_backup_YYYYMMDD_HHMMSS.tar.gz
```

備份包含：
- PostgreSQL 資料庫傾印
- Nextcloud 使用者資料（`data/`）
- Nextcloud 設定檔（`config/`）

### 從備份還原

```bash
./scripts/restore.sh backups/nextcloud_backup_YYYYMMDD_HHMMSS.tar.gz
```

> **警告：** 此操作將覆蓋所有現有資料。系統會要求您確認。

## 實用指令

### 日誌與監控

```bash
# 查看所有服務的即時日誌
docker compose logs -f

# 查看特定服務的日誌
docker compose logs -f nextcloud
docker compose logs -f db
```

### 容器管理

```bash
# 停止所有服務
docker compose down

# 重新啟動所有服務
docker compose restart

# 更新映像檔後重建（拉取最新版本）
docker compose pull && docker compose up -d
```

### Nextcloud 管理（occ 指令）

```bash
# 進入 Nextcloud 容器
docker exec -it nextcloud-app bash

# 直接執行 occ 指令
docker exec -u www-data nextcloud-app php occ <指令>

# 掃描所有使用者檔案
docker exec -u www-data nextcloud-app php occ files:scan --all

# 更新所有應用程式
docker exec -u www-data nextcloud-app php occ app:update --all

# 檢查 Nextcloud 狀態
docker exec -u www-data nextcloud-app php occ status
```

### 資料庫操作

```bash
# 連線到 PostgreSQL
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud

# 檢查資料庫大小
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "SELECT pg_size_pretty(pg_database_size('nextcloud'));"

# 驗證 pgvector 擴充
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

## 疑難排解

### 資料庫連線錯誤

```bash
# 檢查 PostgreSQL 是否健康
docker exec nextcloud-db pg_isready -U nextcloud

# 檢查資料庫日誌
docker compose logs db
```

### 權限問題

```bash
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/data
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/config
```

### 重設管理員密碼

```bash
docker exec -u www-data nextcloud-app php occ user:resetpassword admin
```

### 信任網域錯誤

如果看到「透過不信任的網域存取」：

```bash
# 透過 occ 新增網域
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_domains 1 --value=your-domain.com

# 或更新 .env 中的 NEXTCLOUD_TRUSTED_DOMAINS 後重新啟動
docker compose restart nextcloud
```

### Redis 連線問題

```bash
# 確認 Redis 正在運行
docker exec nextcloud-redis redis-cli ping
# 預期回應：PONG

# 檢查 Redis 日誌
docker compose logs redis
```

## 檔案結構

```
Woow_podman_nextcloud/
├── docker-compose.yml          # 服務定義（4 個容器）
├── .env.example                # 環境變數範本
├── .env                        # 您的設定（已被 git 忽略）
├── .gitignore                  # Git 忽略規則
├── README.md                   # 英文說明文件
├── README_zh-TW.md             # 繁體中文說明文件（本檔案）
├── DEPLOYMENT.md               # 詳細部署指南（英文）
├── DEPLOYMENT_zh-TW.md         # 詳細部署指南（中文）
├── SKILL.md                    # AI 助手部署技能檔
├── LICENSE                     # MIT 授權
├── scripts/
│   ├── backup.sh               # 備份腳本
│   └── restore.sh              # 還原腳本
├── docs/
│   └──（設計文件）
└── data/                       # 執行時資料（已被 git 忽略）
    ├── nextcloud/
    │   ├── html/               # Nextcloud 應用程式檔案
    │   └── data/               # 使用者上傳檔案
    ├── postgres/               # PostgreSQL 資料庫檔案
    └── redis/                  # Redis 持久化資料
```

## 環境變數參考

| 變數 | 預設值 | 必填 | 說明 |
|------|--------|------|------|
| `POSTGRES_DB` | `nextcloud` | 否 | PostgreSQL 資料庫名稱 |
| `POSTGRES_USER` | `nextcloud` | 否 | PostgreSQL 使用者名稱 |
| `POSTGRES_PASSWORD` | - | **是** | PostgreSQL 密碼 |
| `NEXTCLOUD_ADMIN_USER` | `admin` | 否 | Nextcloud 管理員使用者名稱 |
| `NEXTCLOUD_ADMIN_PASSWORD` | - | **是** | Nextcloud 管理員密碼 |
| `NEXTCLOUD_TRUSTED_DOMAINS` | `localhost` | 否 | 信任的網域（空格分隔） |
| `NEXTCLOUD_PORT` | `18080` | 否 | 主機連接埠 |
| `OVERWRITEPROTOCOL` | `https` | 否 | URL 產生使用的協定 |
| `OVERWRITECLIURL` | - | 否 | CLI 操作的完整 URL |
| `TRUSTED_PROXIES` | - | 否 | 信任的代理 CIDR 範圍 |

## 安全注意事項

- **絕對不要將 `.env` 提交**到版本控制（已在 `.gitignore` 中設定）
- 為 `POSTGRES_PASSWORD` 和 `NEXTCLOUD_ADMIN_PASSWORD` 使用強密碼
- 定期更新 Nextcloud 和所有應用程式
- 初始設定後為管理員帳號啟用雙重驗證（2FA）
- 在 **設定** > **總覽** 中檢視 Nextcloud 安全警告

## 更新方式

```bash
# 拉取最新映像檔
docker compose pull

# 使用新映像檔重建容器
docker compose up -d

# 驗證更新
docker exec -u www-data nextcloud-app php occ status
```

## 授權

MIT 授權 - 詳見 [LICENSE](LICENSE)。

---

## 其他部署平台

- **K3s/Kubernetes（Helm chart）** → [Woow_k3s_nextcloud](https://github.com/WOOWTECH/Woow_k3s_nextcloud)
- **Home Assistant add-on** → [Woow_ha_nextcloud](https://github.com/WOOWTECH/Woow_ha_nextcloud)
