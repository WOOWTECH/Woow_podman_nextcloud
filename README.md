# Nextcloud + PostgreSQL (pgvector) Docker/Podman Deployment

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-3.8-blue)](docker-compose.yml)
[![Nextcloud](https://img.shields.io/badge/Nextcloud-Stable-blue)](https://nextcloud.com/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16%20+%20pgvector-336791)](https://github.com/pgvector/pgvector)

[English](#overview) | [繁體中文](README_zh-TW.md)

---

## Overview

Production-ready Nextcloud deployment using Docker/Podman Compose with PostgreSQL 16 (pgvector enabled), Redis caching, and automated background jobs. Optimized for home server and self-hosted environments with Cloudflare Tunnel support.

## Features

| Feature | Description |
|---------|-------------|
| **Nextcloud (Stable)** | Latest stable release with Apache web server |
| **PostgreSQL 16 + pgvector** | Vector database enabling AI features (Recognize app for photo tagging) |
| **Redis** | In-memory caching and file locking for performance |
| **Cron** | Dedicated container for Nextcloud background job processing |
| **Backup/Restore** | Shell scripts for complete data backup and restoration |
| **Cloudflare Tunnel** | Pre-configured for secure external access without port forwarding |
| **Health Checks** | All services include health checks for reliability |

## Architecture

```
Internet
   │
   ▼
Cloudflare Tunnel (SSL termination)
   │
   ▼
Host:18080 ──► nextcloud-app (Apache + PHP)
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
   nextcloud-db  nextcloud-   nextcloud-
   (PostgreSQL    redis        cron
    16+pgvector)  (Cache)     (Background
                               Jobs)
        │
   nextcloud-network (bridge)
```

### Service Details

| Service | Image | Port | Purpose |
|---------|-------|------|---------|
| `nextcloud` | `nextcloud:stable` | `18080:80` | Main application server |
| `db` | `pgvector/pgvector:pg16` | Internal | PostgreSQL database with vector support |
| `redis` | `redis:alpine` | Internal | Cache and file locking |
| `cron` | `nextcloud:stable` | None | Background task runner |

## Deploy to Portainer

Deploy this project instantly using Portainer's Stack feature with our GitHub repository URL.

[![Deploy to Portainer](https://img.shields.io/badge/Deploy_to-Portainer-13BEF9?style=for-the-badge&logo=portainer&logoColor=white)](#deploy-to-portainer)

### Via Git Repository (Recommended)

1. Log in to your Portainer dashboard
2. Navigate to **Stacks** → **Add stack**
3. Select **Repository**
4. Fill in the following:

   | Field | Value |
   |-------|-------|
   | **Repository URL** | `https://github.com/WOOWTECH/Woow_podman_nextcloud` |
   | **Repository reference** | `refs/heads/main` |
   | **Compose path** | `docker-compose.yml` |

5. Click **Deploy the stack**

### Via Web Editor

1. Copy the raw URL of `docker-compose.yml`:

   ```
   https://raw.githubusercontent.com/WOOWTECH/Woow_podman_nextcloud/main/docker-compose.yml
   ```

2. Log in to Portainer → **Stacks** → **Add stack** → **Web editor**
3. Fetch the content from the URL above using `curl` or your browser, paste into the editor
4. Set environment variables (refer to `.env.example`)
5. Click **Deploy the stack**

## Prerequisites

- **Docker** (20.10+) or **Podman** (4.0+) with compose plugin
- **4+ GB RAM** (8-16 GB recommended)
- **4+ CPU cores** recommended
- **20+ GB disk space** (varies with user data)
- (Optional) **Cloudflare account** for tunnel access

## Quick Start

### Step 1: Clone the Repository

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud.git
cd Woow_podman_nextcloud
```

### Step 2: Configure Environment Variables

```bash
cp .env.example .env
nano .env   # or use any text editor
```

**You MUST change these values:**

| Variable | What to Set | Example |
|----------|-------------|---------|
| `POSTGRES_PASSWORD` | Strong database password | `MyS3cur3DbP@ss!` |
| `NEXTCLOUD_ADMIN_PASSWORD` | Strong admin password | `Adm1nP@ssw0rd!` |
| `NEXTCLOUD_TRUSTED_DOMAINS` | Your domains (space-separated) | `localhost cloud.example.com 192.168.1.100` |

### Step 3: Create Data Directories

```bash
mkdir -p data/{nextcloud/html,nextcloud/data,postgres,redis}
```

### Step 4: Start All Services

```bash
# Using Docker Compose
docker compose up -d

# Using Podman Compose
podman-compose up -d
```

### Step 5: Verify Services are Running

```bash
# Check service status
docker compose ps        # or: podman-compose ps

# Expected output: all services "Up" or "healthy"
```

### Step 6: Enable pgvector Extension

```bash
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

### Step 7: Access Nextcloud

- **Local access:** http://localhost:18080
- **Via Cloudflare Tunnel:** https://your-domain.com

Login with the admin credentials you configured in `.env`.

## Post-Installation Configuration

### Install Recognize App (AI Photo Tagging)

1. Login as admin
2. Navigate to **Apps** > Search for "**Recognize**"
3. Click **Install**
4. Configure under **Settings** > **Recognize**

### Set Background Jobs to Cron

1. Go to **Settings** > **Basic settings**
2. Under **Background jobs**, select **Cron**

### Cloudflare Tunnel Setup

1. Create a tunnel in the [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) dashboard
2. Point the public hostname to: `http://localhost:18080`
3. Add your domain to `NEXTCLOUD_TRUSTED_DOMAINS` in `.env`
4. Set `OVERWRITEPROTOCOL=https` in `.env`
5. Restart: `docker compose restart nextcloud`

## Backup & Restore

### Create a Backup

```bash
./scripts/backup.sh
# Output: backups/nextcloud_backup_YYYYMMDD_HHMMSS.tar.gz
```

The backup includes:
- PostgreSQL database dump
- Nextcloud user data (`data/`)
- Nextcloud configuration (`config/`)

### Restore from Backup

```bash
./scripts/restore.sh backups/nextcloud_backup_YYYYMMDD_HHMMSS.tar.gz
```

> **Warning:** This will overwrite all existing data. You will be asked to confirm.

## Useful Commands

### Logs and Monitoring

```bash
# View real-time logs for all services
docker compose logs -f

# View logs for a specific service
docker compose logs -f nextcloud
docker compose logs -f db
```

### Container Management

```bash
# Stop all services
docker compose down

# Restart all services
docker compose restart

# Rebuild and restart (after image updates)
docker compose pull && docker compose up -d
```

### Nextcloud Administration (occ)

```bash
# Enter Nextcloud container
docker exec -it nextcloud-app bash

# Run occ commands directly
docker exec -u www-data nextcloud-app php occ <command>

# Scan all user files
docker exec -u www-data nextcloud-app php occ files:scan --all

# Update all apps
docker exec -u www-data nextcloud-app php occ app:update --all

# Check Nextcloud status
docker exec -u www-data nextcloud-app php occ status
```

### Database Operations

```bash
# Connect to PostgreSQL
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud

# Check database size
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "SELECT pg_size_pretty(pg_database_size('nextcloud'));"

# Verify pgvector extension
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

## Troubleshooting

### Database Connection Error

```bash
# Check PostgreSQL is healthy
docker exec nextcloud-db pg_isready -U nextcloud

# Check database logs
docker compose logs db
```

### Permission Issues

```bash
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/data
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/config
```

### Reset Admin Password

```bash
docker exec -u www-data nextcloud-app php occ user:resetpassword admin
```

### Trusted Domain Error

If you see "Access through untrusted domain":

```bash
# Add domain via occ
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_domains 1 --value=your-domain.com

# Or update NEXTCLOUD_TRUSTED_DOMAINS in .env and restart
docker compose restart nextcloud
```

### Redis Connection Issues

```bash
# Verify Redis is running
docker exec nextcloud-redis redis-cli ping
# Expected: PONG

# Check Redis logs
docker compose logs redis
```

## File Structure

```
Woow_podman_nextcloud/
├── docker-compose.yml          # Service definitions (4 containers)
├── .env.example                # Environment variable template
├── .env                        # Your configuration (git-ignored)
├── .gitignore                  # Git ignore rules
├── README.md                   # English documentation (this file)
├── README_zh-TW.md             # 繁體中文說明文件
├── DEPLOYMENT.md               # Detailed deployment guide (English)
├── DEPLOYMENT_zh-TW.md         # 詳細部署指南（中文）
├── SKILL.md                    # AI assistant deployment skill
├── LICENSE                     # MIT License
├── scripts/
│   ├── backup.sh               # Backup script
│   └── restore.sh              # Restore script
├── docs/
│   └── (design documents)
└── data/                       # Runtime data (git-ignored)
    ├── nextcloud/
    │   ├── html/               # Nextcloud application files
    │   └── data/               # User uploaded files
    ├── postgres/               # PostgreSQL database files
    └── redis/                  # Redis persistence
```

## Environment Variables Reference

| Variable | Default | Required | Description |
|----------|---------|----------|-------------|
| `POSTGRES_DB` | `nextcloud` | No | PostgreSQL database name |
| `POSTGRES_USER` | `nextcloud` | No | PostgreSQL username |
| `POSTGRES_PASSWORD` | - | **Yes** | PostgreSQL password |
| `NEXTCLOUD_ADMIN_USER` | `admin` | No | Nextcloud admin username |
| `NEXTCLOUD_ADMIN_PASSWORD` | - | **Yes** | Nextcloud admin password |
| `NEXTCLOUD_TRUSTED_DOMAINS` | `localhost` | No | Trusted domains (space-separated) |
| `NEXTCLOUD_PORT` | `18080` | No | Host port for Nextcloud |
| `OVERWRITEPROTOCOL` | `https` | No | Protocol for URL generation |
| `OVERWRITECLIURL` | - | No | Full URL for CLI operations |
| `TRUSTED_PROXIES` | - | No | Trusted proxy CIDR ranges |

## Security Notes

- **Never commit `.env`** to version control (already in `.gitignore`)
- Use strong, unique passwords for `POSTGRES_PASSWORD` and `NEXTCLOUD_ADMIN_PASSWORD`
- Keep Nextcloud and all apps updated regularly
- Enable 2FA for admin accounts after initial setup
- Review Nextcloud security warnings under **Settings** > **Overview**

## Updating

```bash
# Pull latest images
docker compose pull

# Recreate containers with new images
docker compose up -d

# Verify update
docker exec -u www-data nextcloud-app php occ status
```

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Other deployment platforms

- **K3s/Kubernetes (Helm chart)** → [Woow_k3s_nextcloud](https://github.com/WOOWTECH/Woow_k3s_nextcloud)
- **Home Assistant add-on** → [Woow_ha_nextcloud](https://github.com/WOOWTECH/Woow_ha_nextcloud)
