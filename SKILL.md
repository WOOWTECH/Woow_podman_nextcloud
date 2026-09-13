# Skill: Deploy Nextcloud + PostgreSQL (rootless Podman Quadlet)

## Metadata

- **Name**: deploy-nextcloud-postgres
- **Description**: Deploy Nextcloud with PostgreSQL 16 (pgvector) and Redis as rootless
  Podman Quadlet units managed by the user's systemd
- **Trigger**: the user asks to deploy Nextcloud, set up self-hosted file storage, or migrate
  an existing Nextcloud compose / manual deployment
- **Repository**: https://github.com/WOOWTECH/Woow_podman_nextcloud

## Prerequisites

- Ubuntu 24.04 or similar, rootless podman >= 4.9.3, systemd 255 user units
- linger enabled for the service user: `sudo loginctl enable-linger $USER`
- `HOST_POSTGRES_DIR` on a local filesystem — never NFS or SMB
- Never run these scripts as root or through `sudo`: the containers belong to the user.

## Fresh install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud ~/woow-quadlet/Woow_podman_nextcloud
cd ~/woow-quadlet/Woow_podman_nextcloud
tests/dryrun.sh                              # validates the units, creates nothing
scripts/install.sh                           # creates ~/.config/nextcloud/nextcloud.env, then stops
# edit HOST_BIND, HOST_PORT, the four HOST_*_DIR paths and NEXTCLOUD_TRUSTED_DOMAINS
scripts/install.sh                           # installs, starts, runs tests/smoke.sh
podman secret inspect --showsecret nextcloud-admin-password
```

`install.sh` is idempotent: run it again after any change to the repo or the env file. It
restarts only the units whose file or environment changed. On a fresh install it also sets the
cron background-job mode, creates the `vector` extension and adds the missing indices.

**Trusted domains:** every name or address the instance is reached by must be in
`NEXTCLOUD_TRUSTED_DOMAINS` before the first start, or Nextcloud answers "access through
untrusted domain".

## Verify

```bash
tests/smoke.sh                               # units, healthchecks, status.php, occ, cron, listeners
curl -fsS http://127.0.0.1:18080/status.php  # installed:true, maintenance:false
systemctl --user list-timers nextcloud-cron.timer
```

## Migrate an existing compose or manual deployment

```bash
scripts/migrate-legacy.sh --legacy-dir <old checkout with .env> --dry-run
scripts/migrate-legacy.sh --legacy-dir <old checkout> --bind 0.0.0.0 --prepare-only
scripts/migrate-legacy.sh --legacy-dir <old checkout> --bind 0.0.0.0 --yes
scripts/migrate-legacy.sh --rollback --yes   # if anything is wrong
```

The html, data, PostgreSQL and Redis directories are adopted where they are — read out of
`podman inspect`, never guessed or copied. The legacy containers are renamed
`<name>-legacy-YYYYMMDD` and `podman-nextcloud.service` is disabled but kept, which is what
makes the rollback fast.

**Always run the dry-run first.** On a host-network deployment PostgreSQL trusted
`127.0.0.1`, so `config.php`'s password for `oc_admin` has never been verified; the dry-run
checks it against the SCRAM verifier and `--fix-db-password` repairs it before the window.

## Day-2 operations

| Task | Command |
|---|---|
| occ | `podman exec -u www-data nextcloud-app php /var/www/html/occ <cmd>` |
| logs | `journalctl --user -u nextcloud-app.service -f` |
| restart the stack | `systemctl --user restart nextcloud.target` |
| run cron.php now | `systemctl --user start nextcloud-cron.service` |
| upgrade | bump `Image=` in `quadlet/nextcloud-app.container`, `git pull`, `scripts/upgrade.sh` |
| backup | `scripts/backup.sh` (add `--cold` for a byte copy of html and PGDATA) |
| restore | `scripts/restore.sh ~/backups/nextcloud/<timestamp>` |
| uninstall | `scripts/uninstall.sh` (`--purge --yes` also deletes the network and secrets) |

## Architecture

```
nextcloud.target
├── nextcloud-db.service     docker.io/pgvector/pgvector:0.8.6-pg16   HOST_POSTGRES_DIR
├── nextcloud-redis.service  docker.io/library/redis:8.10.1-alpine    HOST_REDIS_DIR
├── nextcloud-app.service    docker.io/library/nextcloud:34.0.3-apache
│                            HOST_HTML_DIR -> /var/www/html, HOST_DATA_DIR -> .../data
│                            PublishPort HOST_BIND:HOST_PORT -> 80
└── nextcloud-cron.timer -> nextcloud-cron.service (podman exec ... cron.php, every 5 min)
network nextcloud-network · secrets nextcloud-db-password, nextcloud-admin-password
```

## Rules for an agent working on this repo

1. The repo is the source of truth for versions. Never edit a unit file on the host; change
   `quadlet/*` here and run `scripts/install.sh`.
2. **One Nextcloud major version at a time**, and never pin `nextcloud:stable` — the tag moves,
   and a container that starts on a newer release than the data expects refuses to run.
3. `occ` and `cron.php` always run as `www-data`. Never hide a failed
   `occ maintenance:mode --on` behind `|| true`; that is how backups were taken of a live
   instance before.
4. Never put a password into `~/.config/nextcloud/nextcloud.env` or a unit: use podman secrets.
   Never add a key starting with `NC_` to the env file — Nextcloud reads it as a `config.php`
   override.
5. Never delete a data directory to "clean up". `uninstall.sh --purge` exists, it backs the
   secrets up first, and it deliberately refuses to remove the bind-mounted directories.
6. `scripts/lib/quadlet-lib.sh` is vendored and verified by CI; upstream changes to it belong
   in Woow_quadlet_migration_plan/lib, not here.
