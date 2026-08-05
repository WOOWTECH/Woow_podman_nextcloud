# Nextcloud Docker/Podman Deployment Skill

## Skill Metadata

- **Name:** nextcloud-docker-deployment
- **Description:** Deploy Nextcloud with PostgreSQL (pgvector) using Docker/Podman Compose
- **Trigger:** User asks to deploy Nextcloud, set up a self-hosted cloud storage, or deploy this repository
- **Repository:** https://github.com/WOOWTECH/Woow_podman_nextcloud

---

## Overview

This skill guides an AI assistant through deploying a production-ready Nextcloud instance with PostgreSQL 16 (pgvector), Redis caching, and automated cron jobs using Docker or Podman Compose.

## Stack Components

| Component | Image | Purpose |
|-----------|-------|---------|
| Nextcloud | `nextcloud:stable` | Cloud storage application (port 18080) |
| PostgreSQL | `pgvector/pgvector:pg16` | Database with vector extension for AI features |
| Redis | `redis:alpine` | Caching and file locking |
| Cron | `nextcloud:stable` | Background job processing |

## Deployment Checklist

### Pre-Deployment

- [ ] Verify Docker/Podman is installed: `docker --version` or `podman --version`
- [ ] Verify compose is available: `docker compose version` or `podman-compose --version`
- [ ] Confirm minimum 4 GB RAM available
- [ ] Confirm sufficient disk space (20+ GB)

### Deployment Steps

```bash
# 1. Clone repository
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud.git
cd Woow_podman_nextcloud

# 2. Create and configure .env
cp .env.example .env
# Edit .env: set POSTGRES_PASSWORD, NEXTCLOUD_ADMIN_PASSWORD, NEXTCLOUD_TRUSTED_DOMAINS

# 3. Create data directories
mkdir -p data/{nextcloud/html,nextcloud/data,postgres,redis}

# 4. Start services
docker compose up -d          # Docker
# OR
podman-compose up -d          # Podman

# 5. Wait for healthy status
docker compose ps

# 6. Enable pgvector
docker exec -it nextcloud-db psql -U nextcloud -d nextcloud \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"

# 7. Verify access
curl -I http://localhost:18080
```

### Post-Deployment

- [ ] Access Nextcloud at http://\<server-ip\>:18080
- [ ] Set background jobs to "Cron" in Settings > Basic settings
- [ ] Install Recognize app for AI photo tagging (optional)
- [ ] Configure Cloudflare Tunnel for external access (optional)
- [ ] Set up automated backups with `./scripts/backup.sh`

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `POSTGRES_PASSWORD` | **Yes** | - | Database password (must be strong) |
| `NEXTCLOUD_ADMIN_PASSWORD` | **Yes** | - | Admin password (must be strong) |
| `POSTGRES_DB` | No | `nextcloud` | Database name |
| `POSTGRES_USER` | No | `nextcloud` | Database username |
| `NEXTCLOUD_ADMIN_USER` | No | `admin` | Admin username |
| `NEXTCLOUD_TRUSTED_DOMAINS` | No | `localhost` | Space-separated trusted domains |
| `NEXTCLOUD_PORT` | No | `18080` | Host port |
| `OVERWRITEPROTOCOL` | No | `https` | URL protocol |
| `OVERWRITECLIURL` | No | - | Full CLI URL |
| `TRUSTED_PROXIES` | No | - | Proxy CIDR ranges |

## Password Generation

```bash
# Generate secure passwords
openssl rand -base64 24
# Or
python3 -c "import secrets; print(secrets.token_urlsafe(24))"
```

## Common Operations

### Backup

```bash
./scripts/backup.sh
# Creates: backups/nextcloud_backup_YYYYMMDD_HHMMSS.tar.gz
```

### Restore

```bash
./scripts/restore.sh backups/nextcloud_backup_YYYYMMDD_HHMMSS.tar.gz
```

### Upgrade

```bash
./scripts/backup.sh                    # Backup first
docker compose pull                    # Pull latest images
docker compose up -d                   # Recreate containers
docker exec -u www-data nextcloud-app php occ status  # Verify
```

### Useful occ Commands

```bash
# File scan
docker exec -u www-data nextcloud-app php occ files:scan --all

# Update apps
docker exec -u www-data nextcloud-app php occ app:update --all

# Reset admin password
docker exec -u www-data nextcloud-app php occ user:resetpassword admin

# Check status
docker exec -u www-data nextcloud-app php occ status

# Add missing DB indices
docker exec -u www-data nextcloud-app php occ db:add-missing-indices

# Add trusted domain
docker exec -u www-data nextcloud-app php occ config:system:set \
  trusted_domains 1 --value=your-domain.com
```

## Troubleshooting

| Issue | Diagnosis | Solution |
|-------|-----------|----------|
| DB connection error | `docker exec nextcloud-db pg_isready -U nextcloud` | Check `.env` passwords match, check `docker compose logs db` |
| Permission denied | Files owned by wrong user | `docker exec nextcloud-app chown -R www-data:www-data /var/www/html/data` |
| Untrusted domain | Accessing from IP/domain not in config | Add domain to `NEXTCLOUD_TRUSTED_DOMAINS` in `.env`, restart |
| Redis not connecting | `docker exec nextcloud-redis redis-cli ping` | Check `docker compose logs redis` |
| 502 Bad Gateway | Nextcloud container not ready | Wait for initialization, check `docker compose logs nextcloud` |

## Architecture Diagram

```
Internet → Cloudflare Tunnel (SSL) → Host:18080
                                        │
                                  nextcloud-app
                                   (Apache+PHP)
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              nextcloud-db        nextcloud-redis      nextcloud-cron
           (PostgreSQL 16         (Cache/Lock)        (Background Jobs)
            + pgvector)
```

## Network

All services communicate on `nextcloud-network` (bridge). Only the Nextcloud app container exposes port 18080 to the host.

## Data Persistence

| Path | Container Mount | Content |
|------|-----------------|---------|
| `data/postgres/` | `/var/lib/postgresql/data` | Database files |
| `data/redis/` | `/data` | Redis AOF persistence |
| `data/nextcloud/html/` | `/var/www/html` | Nextcloud application |
| `data/nextcloud/data/` | `/var/www/html/data` | User files |

## Security Notes

- `.env` file is git-ignored (contains secrets)
- Use strong, unique passwords (minimum 16 characters recommended)
- Enable 2FA for admin accounts after deployment
- Keep all images updated regularly
- Review Nextcloud security warnings in Settings > Overview
