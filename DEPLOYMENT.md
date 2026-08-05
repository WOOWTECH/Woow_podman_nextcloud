# Nextcloud Deployment Guide

This guide provides step-by-step instructions for deploying Nextcloud with PostgreSQL (pgvector) using Docker or Podman Compose.

---

## Table of Contents

1. [System Requirements](#1-system-requirements)
2. [Install Container Runtime](#2-install-container-runtime)
3. [Clone the Repository](#3-clone-the-repository)
4. [Configure Environment](#4-configure-environment)
5. [Prepare Data Directories](#5-prepare-data-directories)
6. [Launch the Stack](#6-launch-the-stack)
7. [Verify Deployment](#7-verify-deployment)
8. [Initial Nextcloud Setup](#8-initial-nextcloud-setup)
9. [Configure Cloudflare Tunnel](#9-configure-cloudflare-tunnel)
10. [Enable AI Features (pgvector)](#10-enable-ai-features-pgvector)
11. [Set Up Automated Backups](#11-set-up-automated-backups)
12. [Maintenance Operations](#12-maintenance-operations)
13. [Upgrading](#13-upgrading)
14. [Uninstall / Clean Up](#14-uninstall--clean-up)

---

## 1. System Requirements

### Hardware

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 4 GB | 8-16 GB |
| CPU | 2 cores | 4+ cores |
| Storage | 20 GB | 100+ GB (depending on user data) |
| Network | Stable internet connection | Gigabit LAN |

### Software

| Software | Version | Check Command |
|----------|---------|---------------|
| Docker | 20.10+ | `docker --version` |
| Docker Compose | 2.0+ | `docker compose version` |
| **OR** Podman | 4.0+ | `podman --version` |
| Podman Compose | 1.0+ | `podman-compose --version` |
| Git | 2.0+ | `git --version` |

---

## 2. Install Container Runtime

### Option A: Docker (Recommended for beginners)

**Ubuntu/Debian:**

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh

# Add your user to docker group (avoid using sudo)
sudo usermod -aG docker $USER

# Log out and back in, then verify
docker --version
docker compose version
```

**Fedora/RHEL:**

```bash
sudo dnf install docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
```

### Option B: Podman (Rootless, more secure)

**Ubuntu/Debian:**

```bash
sudo apt update
sudo apt install -y podman podman-compose
podman --version
```

**Fedora/RHEL:**

```bash
sudo dnf install podman podman-compose
```

> **Note:** Throughout this guide, replace `docker compose` with `podman-compose` if using Podman. Replace `docker exec` with `podman exec`.

---

## 3. Clone the Repository

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud.git
cd Woow_podman_nextcloud
```

Verify the directory structure:

```bash
ls -la
# Expected: docker-compose.yml  .env.example  scripts/  README.md  ...
```

---

## 4. Configure Environment

### 4.1 Create .env File

```bash
cp .env.example .env
```

### 4.2 Generate Secure Passwords

```bash
# Generate random passwords
echo "POSTGRES_PASSWORD=$(openssl rand -base64 24)"
echo "NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -base64 24)"
```

### 4.3 Edit Configuration

```bash
nano .env
```

**Required changes:**

```env
# Database - USE A STRONG PASSWORD
POSTGRES_PASSWORD=<your-generated-password>

# Admin - USE A STRONG PASSWORD
NEXTCLOUD_ADMIN_PASSWORD=<your-generated-password>

# Add all domains/IPs you will access Nextcloud from
NEXTCLOUD_TRUSTED_DOMAINS=localhost 192.168.1.100 cloud.your-domain.com
```

**Optional: Customize port (default is 18080):**

```env
NEXTCLOUD_PORT=18080
```

### 4.4 Verify Configuration

```bash
# Check .env has no placeholder passwords
grep "CHANGE_ME" .env
# This should return nothing if you've updated all passwords
```

---

## 5. Prepare Data Directories

```bash
mkdir -p data/{nextcloud/html,nextcloud/data,postgres,redis}
```

Verify:

```bash
tree data/ -L 2
# Expected structure:
# data/
# ├── nextcloud/
# │   ├── data/
# │   └── html/
# ├── postgres/
# └── redis/
```

> **Note:** If `tree` is not installed, use `ls -R data/` instead.

---

## 6. Launch the Stack

### 6.1 Start All Services

```bash
# Docker
docker compose up -d

# Podman
podman-compose up -d
```

### 6.2 Monitor Startup Progress

```bash
# Watch container status (repeat until all show "healthy")
docker compose ps

# Watch real-time logs
docker compose logs -f
```

**Expected startup order:**
1. `nextcloud-db` (PostgreSQL) starts and becomes healthy
2. `nextcloud-redis` starts and becomes healthy
3. `nextcloud-app` starts after db and redis are healthy
4. `nextcloud-cron` starts after nextcloud-app

### 6.3 First-Time Initialization

On the first start, Nextcloud will:
- Initialize the database schema
- Create the admin user
- Install default apps

This may take 1-3 minutes. Monitor with:

```bash
docker compose logs -f nextcloud
```

Wait until you see: `AH00094: Command line: 'apache2 -D FOREGROUND'`

---

## 7. Verify Deployment

### 7.1 Check Service Health

```bash
docker compose ps
```

Expected output:
```
NAME               STATUS                    PORTS
nextcloud-app      Up (healthy)              0.0.0.0:18080->80/tcp
nextcloud-cron     Up
nextcloud-db       Up (healthy)
nextcloud-redis    Up (healthy)
```

### 7.2 Test Web Access

```bash
# From the server
curl -I http://localhost:18080
# Expected: HTTP/1.1 302 Found (redirects to login)
```

### 7.3 Test Database Connection

```bash
docker exec nextcloud-db pg_isready -U nextcloud
# Expected: /var/run/postgresql:5432 - accepting connections
```

### 7.4 Test Redis

```bash
docker exec nextcloud-redis redis-cli ping
# Expected: PONG
```

---

## 8. Initial Nextcloud Setup

### 8.1 Access the Web Interface

Open in your browser: **http://\<server-ip\>:18080**

Login with:
- Username: value of `NEXTCLOUD_ADMIN_USER` in `.env` (default: `admin`)
- Password: value of `NEXTCLOUD_ADMIN_PASSWORD` in `.env`

### 8.2 Configure Background Jobs

1. Go to **Settings** (click your avatar in the top right) > **Basic settings**
2. Under **Background jobs**, select **Cron**
3. The cron container handles this automatically

### 8.3 Verify Redis Caching

1. Go to **Settings** > **Overview**
2. Check that "Memory Caching" shows as configured
3. Or verify via command:

```bash
docker exec -u www-data nextcloud-app php occ config:system:get memcache.distributed
# Expected: \OC\Memcache\Redis
```

### 8.4 Security Hardening

1. Go to **Settings** > **Overview** and address any security warnings
2. Enable **Two-Factor Authentication** for the admin account:
   - Go to **Settings** > **Security** > **Two-Factor Authentication**
   - Install and configure a TOTP app

---

## 9. Configure Cloudflare Tunnel

### 9.1 Prerequisites

- A Cloudflare account
- A domain pointed to Cloudflare DNS
- `cloudflared` installed on your server

### 9.2 Install cloudflared

```bash
# Debian/Ubuntu
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install cloudflared
```

### 9.3 Create and Configure Tunnel

```bash
# Login to Cloudflare
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create nextcloud

# Configure tunnel
cat > ~/.cloudflared/config.yml << EOF
tunnel: <TUNNEL-ID>
credentials-file: /home/$USER/.cloudflared/<TUNNEL-ID>.json

ingress:
  - hostname: cloud.your-domain.com
    service: http://localhost:18080
  - service: http_status:404
EOF

# Route DNS
cloudflared tunnel route dns nextcloud cloud.your-domain.com
```

### 9.4 Update Nextcloud Configuration

Update `.env`:

```env
NEXTCLOUD_TRUSTED_DOMAINS=localhost cloud.your-domain.com
OVERWRITEPROTOCOL=https
OVERWRITECLIURL=https://cloud.your-domain.com
TRUSTED_PROXIES=172.16.0.0/12
```

Restart Nextcloud:

```bash
docker compose restart nextcloud
```

### 9.5 Start Tunnel as Service

```bash
sudo cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

---

## 10. Enable AI Features (pgvector)

### 10.1 Enable pgvector Extension

```bash
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

Verify:

```bash
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

### 10.2 Install Recognize App

1. Login as admin in Nextcloud
2. Go to **Apps** > Search "**Recognize**"
3. Click **Install and Enable**
4. Go to **Settings** > **Recognize** to configure
5. The app will use pgvector for efficient similarity searches

---

## 11. Set Up Automated Backups

### 11.1 Manual Backup

```bash
./scripts/backup.sh
```

### 11.2 Schedule Automated Backups (cron)

```bash
# Edit crontab
crontab -e

# Add daily backup at 3:00 AM
0 3 * * * /path/to/Woow_podman_nextcloud/scripts/backup.sh >> /var/log/nextcloud-backup.log 2>&1
```

### 11.3 Backup Rotation

Keep recent backups, remove old ones:

```bash
# Keep last 7 days of backups
find /path/to/backups/ -name "nextcloud_backup_*.tar.gz" -mtime +7 -delete
```

Add this to crontab after the backup command:

```bash
30 3 * * * find /path/to/Woow_podman_nextcloud/backups/ -name "nextcloud_backup_*.tar.gz" -mtime +7 -delete
```

---

## 12. Maintenance Operations

### 12.1 Enable/Disable Maintenance Mode

```bash
# Enable (blocks user access)
docker exec -u www-data nextcloud-app php occ maintenance:mode --on

# Disable
docker exec -u www-data nextcloud-app php occ maintenance:mode --off
```

### 12.2 File Scan

After manually adding/moving files:

```bash
docker exec -u www-data nextcloud-app php occ files:scan --all
```

### 12.3 Fix Permissions

```bash
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/data
docker exec nextcloud-app chown -R www-data:www-data /var/www/html/config
```

### 12.4 Check System Status

```bash
docker exec -u www-data nextcloud-app php occ status
docker exec -u www-data nextcloud-app php occ config:system:get version
```

### 12.5 Database Maintenance

```bash
# Add missing database indices
docker exec -u www-data nextcloud-app php occ db:add-missing-indices

# Convert filecache bigint columns
docker exec -u www-data nextcloud-app php occ db:convert-filecache-bigint
```

---

## 13. Upgrading

### 13.1 Standard Upgrade

```bash
# 1. Backup first
./scripts/backup.sh

# 2. Pull latest images
docker compose pull

# 3. Recreate containers
docker compose up -d

# 4. Verify
docker exec -u www-data nextcloud-app php occ status
docker exec -u www-data nextcloud-app php occ app:update --all
```

### 13.2 Major Version Upgrade

For major version upgrades (e.g., NC 28 -> 29):

```bash
# 1. Backup
./scripts/backup.sh

# 2. Enable maintenance mode
docker exec -u www-data nextcloud-app php occ maintenance:mode --on

# 3. Pull and recreate
docker compose pull
docker compose up -d

# 4. Run upgrade
docker exec -u www-data nextcloud-app php occ upgrade

# 5. Disable maintenance mode
docker exec -u www-data nextcloud-app php occ maintenance:mode --off

# 6. Update apps
docker exec -u www-data nextcloud-app php occ app:update --all
```

---

## 14. Uninstall / Clean Up

### 14.1 Stop and Remove Containers

```bash
docker compose down
```

### 14.2 Remove Data (DESTRUCTIVE)

```bash
# WARNING: This permanently deletes ALL data
sudo rm -rf data/
```

### 14.3 Remove Images

```bash
docker rmi nextcloud:stable pgvector/pgvector:pg16 redis:alpine
```

### 14.4 Remove Volumes and Networks

```bash
docker network rm nextcloud-network 2>/dev/null || true
```
