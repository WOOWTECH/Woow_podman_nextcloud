# Nextcloud on rootless Podman (Quadlet + systemd)

[Nextcloud](https://nextcloud.com/) with PostgreSQL 16 (pgvector) and Redis, deployed as
**rootless Podman Quadlet units** driven by the user's systemd. The units are the deployment:
systemd starts the stack at boot (with linger), restarts a crashed container, runs the
background jobs from a timer and keeps every version pinned in this repository.

[繁體中文版](README_zh-TW.md)

## Architecture

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
                              (127.0.0.1:18080 by default; a Cloudflare
                               tunnel or NPM provides public access)

        nextcloud-cron.timer ──every 5 min──> nextcloud-cron.service
              podman exec -u www-data nextcloud-app php -f cron.php
```

| File | Unit | What it is |
|---|---|---|
| `quadlet/nextcloud.network` | `nextcloud-network.service` | bridge network `nextcloud-network` |
| `quadlet/nextcloud-db.container` | `nextcloud-db.service` | PostgreSQL 16 + pgvector |
| `quadlet/nextcloud-redis.container` | `nextcloud-redis.service` | distributed memcache and file locking |
| `quadlet/nextcloud-app.container` | `nextcloud-app.service` | Nextcloud (Apache, port 80 inside) |
| `systemd/nextcloud-cron.service` | `nextcloud-cron.service` | one run of `cron.php` |
| `systemd/nextcloud-cron.timer` | `nextcloud-cron.timer` | every 5 minutes |
| `systemd/nextcloud.target` | `nextcloud.target` | one handle for the whole stack |

Installed to `~/.config/containers/systemd/` (Quadlet), `~/.config/systemd/user/` (the target,
the cron service and its timer) and `~/.config/nextcloud/nextcloud.env` (settings, mode 0600).
Passwords are podman secrets, never env files.

**There is no cron container.** The old `nextcloud-cron` container ran busybox crond; a
`Type=oneshot` service behind a timer cannot overlap runs, shows up in
`systemctl --user list-timers`, and is skipped rather than failed while the app is down.

**The database and Redis are on a private bridge**, not on the host's loopback. The previous
manual deployment ran every container with `--network host`, where `pg_hba.conf`'s
`trust 127.0.0.1` meant any local process — including every other host-network container —
could connect to PostgreSQL as a superuser without a password, and to Redis without auth.

## Requirements

- Ubuntu 24.04 or similar, **podman >= 4.9.3** rootless, systemd 255 user units
- linger for the service user (`sudo loginctl enable-linger $USER`), so the stack survives logout
- about 1.3 GB of disk for the images, plus the html directory (~900 MB), the database and
  the user files
- the PostgreSQL directory must be on a **local filesystem** (never NFS or SMB);
  `install.sh` checks

```bash
podman --version && systemctl --user show-environment >/dev/null && echo "user manager ok"
```

## Install

```bash
git clone https://github.com/WOOWTECH/Woow_podman_nextcloud ~/woow-quadlet/Woow_podman_nextcloud
cd ~/woow-quadlet/Woow_podman_nextcloud
tests/dryrun.sh                               # optional: validates the units, creates nothing
scripts/install.sh                            # first run: creates the env file, then stops
$EDITOR ~/.config/nextcloud/nextcloud.env     # the four HOST_*_DIR paths and the trusted domains
scripts/install.sh                            # installs, starts and runs the smoke test
```

The first install waits for the entrypoint to unpack Nextcloud, then sets the cron
background-job mode, creates the `vector` extension and adds the missing database indices.
It prints how to read the generated admin password:

```bash
podman secret inspect --showsecret nextcloud-admin-password
```

Open `http://127.0.0.1:18080/` (or whatever `HOST_BIND:HOST_PORT` you set). **Every name or
address you reach it by must be in `NEXTCLOUD_TRUSTED_DOMAINS`**, or Nextcloud answers
"access through untrusted domain".

Options: `--db-password-file F` and `--admin-password-file F` (first install only),
`--no-start`, `--no-smoke`, `--smoke-timeout S`, `--dry-run` (render and validate only).

## Configuration

`~/.config/nextcloud/nextcloud.env`, mode 0600, `KEY=value` lines only — no quotes, no
`export`, no inline comments. `HOST_*` keys are rendered into the unit files at install time
(decision D2); every other key is passed to the app container, so the
[image's environment variables](https://github.com/nextcloud/docker#environment-variables)
work. Re-run `scripts/install.sh` after an edit: it restarts only what changed.

| Key | Default | Meaning |
|---|---|---|
| `HOST_BIND` | `127.0.0.1` | publish address. `0.0.0.0` exposes Nextcloud on every interface |
| `HOST_PORT` | `18080` | published port (Apache listens on 80 inside the container) |
| `HOST_HTML_DIR` | `%h/.local/share/nextcloud/html` | `/var/www/html`: the code, the apps and `config/config.php` |
| `HOST_DATA_DIR` | `%h/.local/share/nextcloud/data` | `/var/www/html/data`: the user files — the one that grows |
| `HOST_POSTGRES_DIR` | `%h/.local/share/nextcloud/postgres` | PGDATA. Local disk only |
| `HOST_REDIS_DIR` | `%h/.local/share/nextcloud/redis` | the Redis append-only file |
| `NEXTCLOUD_ADMIN_USER` | `admin` | first install only |
| `NEXTCLOUD_TRUSTED_DOMAINS` | `localhost 127.0.0.1` | space-separated; written on the first start |
| `OVERWRITEPROTOCOL` | empty | set `https` behind a TLS proxy or tunnel that sends no `X-Forwarded-Proto` |
| `OVERWRITECLIURL`, `TRUSTED_PROXIES` | empty | read by the image's `reverse-proxy.config.php` |
| `PHP_MEMORY_LIMIT`, `PHP_UPLOAD_LIMIT` | `512M` | PHP limits |

Each `HOST_*_DIR` is an absolute path, or starts with `%h/` for your home directory. A path
that already holds a Nextcloud is adopted as it is — nothing is copied or moved (decision D9).

**Never add a key starting with `NC_`.** Nextcloud reads `NC_<key>` as an override of
`config.php`; `install.sh` refuses the env file if it finds one. The units set `NC_dbhost` and
`REDIS_HOST` themselves, which is how an adopted instance whose `config.php` still says
`dbhost=127.0.0.1` reaches the database on the bridge without its configuration being edited
— and how it can be rolled back without an edit either.

`POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER` and `REDIS_HOST` are fixed in the unit
(`--env` beats `--env-file`), so they cannot drift from the database unit.

**Secrets** (podman secrets, created on the first install, never printed):

| Secret | Used by |
|---|---|
| `nextcloud-db-password` | `POSTGRES_PASSWORD`: initdb, and Nextcloud's first install |
| `nextcloud-admin-password` | `NEXTCLOUD_ADMIN_PASSWORD`: install-time only, ignored afterwards |

Once Nextcloud is installed it authenticates as the `oc_admin` role with the `dbpassword` in
`config.php`, which is Nextcloud-owned state inside the html directory.

## Operations

```bash
systemctl --user status nextcloud-app.service       # one unit
systemctl --user restart nextcloud.target           # the whole stack
journalctl --user -u nextcloud-app.service -f       # logs (LogDriver=journald)
systemctl --user list-timers nextcloud-cron.timer   # when cron.php runs next
systemctl --user start nextcloud-cron.service       # run the background jobs now
tests/smoke.sh                                      # health checks
tests/smoke.sh --public-url https://cloud.example.com/
```

`occ` refuses to run as root, so always run it as `www-data`:

```bash
occ() { podman exec -u www-data nextcloud-app php /var/www/html/occ "$@"; }

occ status
occ user:list
occ files:scan --all
occ app:update --all
occ config:system:set trusted_domains 2 --value=cloud.example.com
```

The database:

```bash
podman exec -it nextcloud-db psql -U nextcloud -d nextcloud
podman exec nextcloud-db psql -U nextcloud -d nextcloud -c "SELECT pg_size_pretty(pg_database_size('nextcloud'));"
```

### AI photo tagging (Recognize)

`install.sh` creates the `vector` extension on a fresh install, so the
[Recognize](https://apps.nextcloud.com/apps/recognize) app can be installed from
**Apps** and configured under **Settings → Recognize**. On an adopted instance, check it:

```bash
podman exec nextcloud-db psql -U nextcloud -d nextcloud -c "SELECT extname, extversion FROM pg_extension;"
```

### Behind a Cloudflare tunnel or Nginx Proxy Manager

Keep `HOST_BIND=127.0.0.1`, point the tunnel or proxy at `http://localhost:18080`, and set in
`~/.config/nextcloud/nextcloud.env`:

```ini
OVERWRITEPROTOCOL=https
OVERWRITECLIURL=https://cloud.example.com
TRUSTED_PROXIES=127.0.0.1
NEXTCLOUD_TRUSTED_DOMAINS=localhost cloud.example.com
```

Then `scripts/install.sh` again. Without `TRUSTED_PROXIES` Nextcloud sees the bridge gateway
as the client for every request, which shares brute-force throttling across all users and
loses the real IP in the log.

The tunnel itself is deployed from
[Woow_cloudflare_tunnel_webgui](https://github.com/WOOWTECH/Woow_cloudflare_tunnel_webgui);
this repository does not install `cloudflared`.

## Upgrade

The repository is the source of truth: bump `Image=` in `quadlet/nextcloud-app.container`,
commit, then:

```bash
git pull
scripts/upgrade.sh            # --repair also runs maintenance:repair --include-expensive
```

**One major version at a time.** Nextcloud's entrypoint refuses to skip a major — but only
after the old container is already gone, so `upgrade.sh` compares the installed `version.php`
with the image's `NEXTCLOUD_VERSION` and declines before anything stops. It also refuses a
downgrade and a PostgreSQL major change.

It then takes a cold backup (the dump, the roles, `config/`, the html directory and the
database directory), installs the new unit, and polls `status.php` for up to 30 minutes:
`--sdnotify=conmon` marks the unit active while the entrypoint is still rsyncing the release
and running `occ upgrade`. Afterwards it adds missing indices, columns and primary keys and
updates the apps. **On failure it rolls back automatically** — Nextcloud cannot downgrade, so
the html directory and the database go back together.

Never pin `nextcloud:stable`. That tag moves, and a container that starts on a newer release
than the data expects refuses to run.

**PostgreSQL major upgrade** (16 → 17) is a separate job: `scripts/backup.sh --cold`, bump the
database image, move `HOST_POSTGRES_DIR` aside, `scripts/install.sh`, then `scripts/restore.sh`.

## Backup and restore

```bash
scripts/backup.sh                    # maintenance mode, DB dump + roles, config, user files
scripts/backup.sh --no-data          # skip the user files
scripts/backup.sh --cold             # also stops the stack: html and PGDATA byte for byte
scripts/restore.sh ~/backups/nextcloud/<timestamp> [--with-html] [--yes]
```

A backup directory is mode 0700 and carries `SHA256SUMS`, which `restore.sh` verifies. It
holds the database password and the admin password: store copies off this host and treat them
accordingly. `roles.sql` travels with the dump because `config.php` authenticates as
`oc_admin` and `pg_dump` does not carry roles.

Maintenance mode is switched on for the duration and off again by a trap, **including when the
backup fails** — unlike the previous script, which hid a failed `occ maintenance:mode --on`
behind `|| true` and backed up a live instance.

A nightly backup, as the service user:

```bash
systemd-run --user --on-calendar='*-*-* 03:30:00' --unit=nextcloud-backup \
  ~/woow-quadlet/Woow_podman_nextcloud/scripts/backup.sh
```

## Uninstall

```bash
scripts/uninstall.sh                 # stops and removes the units and the timer; keeps all data
scripts/uninstall.sh --purge --yes   # also deletes the network and both secrets
```

`--purge` exports both secrets and the env file to `~/backups/nextcloud/purge-<timestamp>/`
first, and it **never** deletes the four data directories: it prints the
`podman unshare rm -rf` commands for them, so a mistyped path cannot destroy user files.

## Migrating an existing compose or manual deployment

`scripts/migrate-legacy.sh` adopts the html, data, PostgreSQL and Redis directories where they
are — read out of `podman inspect`, not guessed, and never copied — and keeps the legacy
containers and unit for rollback. Downtime is 8–12 minutes of maintenance mode; book 30.

```bash
# 1. check and prepare while the old stack keeps running (no downtime)
scripts/migrate-legacy.sh --legacy-dir ~/podman/nextcloud --dry-run
scripts/migrate-legacy.sh --legacy-dir ~/podman/nextcloud --bind 0.0.0.0 --prepare-only

# 2. cutover (downtime starts): maintenance mode, dump, stop, cold tar, retire, install, smoke
scripts/migrate-legacy.sh --legacy-dir ~/podman/nextcloud --bind 0.0.0.0 --yes

# 3. if anything is wrong (about 3 minutes; both stacks share the same directories)
scripts/migrate-legacy.sh --rollback --yes
```

**The database password is the thing to check first.** A host-network deployment reached
PostgreSQL over `127.0.0.1`, which `pg_hba.conf` trusts, so the password `config.php` holds
for `oc_admin` has never actually been used. On the bridge it has to work. Step 1 verifies it
against the SCRAM verifier in `pg_authid` — printing only `match=true` or `match=false`, never
the password — and refuses the cutover on a mismatch. `--fix-db-password` sets the role's
password to the one `config.php` already uses, which changes nothing for the legacy stack.

What else the migration changes on purpose: host networking becomes the bridge (so the
`apache-ports.conf` / `apache-site.conf` overrides are retired and Apache listens on 80 inside
the container), the cron container becomes the timer, the floating tags `stable`, `pg16` and
`alpine` become the exact versions they resolve to today, and the passwords move out of the
legacy `.env` — which the database container also received, admin password included — into
podman secrets.

The cutover saves `config.php` before the new stack starts: the first configuration write
persists `redis.host=nextcloud-redis` into it, and `--rollback` puts the saved copy back.

### How the legacy containers are kept for rollback

Renaming a legacy container and leaving it stopped is a rollback path only while nothing
starts it again. The user unit `podman-restart.service` runs
`podman start --all --filter restart-policy=always` at boot, so on a host where that unit is
**enabled** a renamed, stopped container whose restart policy is exactly `always` revives at
the next boot and fights the new Quadlet container for its name, ports and volumes — here, a second
PostgreSQL and a second Apache on the same html and data directories.
podman 4.9.3 cannot repair that afterwards: `podman update` only rewrites cgroup limits, and a
restart policy is fixed at create time.

The script therefore asks `ql_rollback_strategy` — which reads this host's real state, never
its name — and takes one of two paths. `--dry-run` prints which one applies here.

| Answer | When | What the cutover does | What `--rollback` does |
|---|---|---|---|
| `rename` | the unit is disabled, or no legacy container has policy `always` | `podman rename <name> <name>-legacy-YYYYMMDD`, left stopped | renames it back |
| `capture` | the unit is enabled **and** a legacy container has policy `always` | writes `<backup>/legacy-container/<name>/` (inspect, create command, image, policy, mounts, networks) and then a plain `podman rm` — never `podman rm -v`, which would delete the anonymous volumes | `ql_recreate_container` recreates it stopped, with its original restart policy |

On `woowtechopenclaw` all four compose-era Nextcloud containers carry `restart=always`
and `podman-restart.service` is enabled, so a migration there takes the `capture` path. On
`toypark1234` that unit is disabled, so the migration already done there keeps the `rename`
path unchanged.

Earlier versions of this script simply refused to run while `podman-restart.service` was
enabled. That was safe but it blocked the migration outright; the capture path performs it
correctly instead.

The capture cannot bring back a container's **writable layer** — anything written inside the
container that did not land in a volume or a bind mount. Nextcloud keeps its code, config, apps and data in the html and
data bind mounts, and the live containers' writable layers hold about 13 kB of runtime
scratch, so nothing of value is lost. (`ql_capture_container --commit` exists for a stack
that mutates its own container; Nextcloud does not need it.) The container id and the IP/MAC
lease are not preserved either. `tests/rollback-model.sh` pins both paths.

**After the soak period** (two weeks, including one reboot):

```bash
# on the rename path; the capture path removed them at the cutover
podman rm nextcloud-app-legacy-YYYYMMDD nextcloud-cron-legacy-YYYYMMDD \
          nextcloud-db-legacy-YYYYMMDD nextcloud-redis-legacy-YYYYMMDD
rm ~/.config/systemd/user/podman-nextcloud.service ~/.local/bin/start-migrated-nextcloud
systemctl --user daemon-reload
podman untag docker.io/library/nextcloud:stable docker.io/pgvector/pgvector:pg16 docker.io/library/redis:alpine
occ config:system:set dbhost --value=nextcloud-db     # config.php now says what is true
occ config:system:get trusted_domains                 # drop any stale entry by its index
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Unit nextcloud-app.service not found` | the generator rejected a file. Run `tests/dryrun.sh`, then `systemctl --user daemon-reload` |
| install refuses: *legacy container* | a non-Quadlet container owns the name. Quadlet's `--replace` would delete it: rename it (the message prints the command) or use `migrate-legacy.sh` |
| "Access through untrusted domain" | add the name to `NEXTCLOUD_TRUSTED_DOMAINS` and re-run `install.sh`, or `occ config:system:set trusted_domains N --value=…` |
| `password authentication failed for user "oc_admin"` | the adopted `config.php` password never passed real auth. `scripts/migrate-legacy.sh --fix-db-password` |
| `occ` says *Console has to be executed with the user that owns the file* | you ran it without `-u www-data` |
| links use `http://` behind a tunnel | set `OVERWRITEPROTOCOL=https` and `TRUSTED_PROXIES` |
| background jobs stop advancing | `systemctl --user list-timers nextcloud-cron.timer`, then `journalctl --user -u nextcloud-cron.service` |
| the stack does not come back after a reboot | linger is off: `sudo loginctl enable-linger $USER` |
| `occ config:system:get dbhost` says `127.0.0.1` | harmless on an adopted instance: the unit's `NC_dbhost` overrides it and is never written back |

## Docker Compose

This repository is Quadlet-only. The last revision with `docker-compose.yml` is tagged
[`compose-final`](https://github.com/WOOWTECH/Woow_podman_nextcloud/tree/compose-final):

```bash
git clone --branch compose-final https://github.com/WOOWTECH/Woow_podman_nextcloud
```

New Docker deployments should follow Nextcloud's own
[docker examples](https://github.com/nextcloud/docker#running-this-image-with-docker-compose).

## License

MIT License — see [LICENSE](LICENSE).

## Other deployment platforms

- **K3s / Kubernetes (Helm chart)** → [Woow_k3s_nextcloud](https://github.com/WOOWTECH/Woow_k3s_nextcloud)
- **Home Assistant add-on** → [Woow_ha_nextcloud](https://github.com/WOOWTECH/Woow_ha_nextcloud)
