#!/usr/bin/env bash
# scripts/migrate-legacy.sh: move a compose or hand-made Nextcloud deployment (containers
# nextcloud-app, nextcloud-cron, nextcloud-db, nextcloud-redis and a hand-written
# podman-nextcloud.service) to the Quadlet units of this repo. The html, data, database and
# Redis directories are adopted where they are: no data is copied, and the legacy containers
# and unit stay for --rollback.
#
#   scripts/migrate-legacy.sh --legacy-dir DIR [--bind ADDR] [--port N] [--suffix YYYYMMDD]
#                             [--fix-db-password] [--backup-data]
#                             [--prepare-only | --dry-run] [--no-auto-rollback] [--yes]
#   scripts/migrate-legacy.sh --rollback [--yes]
#   scripts/migrate-legacy.sh --status
#
#   --legacy-dir DIR     the old checkout; its .env holds POSTGRES_PASSWORD and the admin one
#   --bind ADDR          HOST_BIND of the new publish (default 0.0.0.0, which is what host
#                        networking with Apache on :18080 effectively was)
#   --port N             HOST_PORT (default: NEXTCLOUD_PORT from the legacy .env, else 18080)
#   --fix-db-password    set the database role's password to the one in config.php. On host
#                        networking pg_hba trusted 127.0.0.1, so that password has never
#                        been checked; on the bridge it suddenly has to work.
#   --backup-data        also archive the user files during the cutover (they are adopted in
#                        place and never rewritten, so this is off by default)
#   --prepare-only       steps 1-2 only, no downtime
#   --dry-run            step 1 and a render of the units; changes nothing
#   --no-auto-rollback   leave a failed cutover in place for inspection
#   --rollback           undo the cutover, including config.php
#
# Rollback shape (STANDARD 7a): the legacy containers are kept for --rollback either by
# renaming them and leaving them stopped, or - where the user unit podman-restart.service is
# enabled and a legacy container's restart policy is exactly `always`, as the compose-era
# Nextcloud containers are, because a renamed copy would revive at the next boot and open the
# same data directories next to the new stack - by capturing them into the backup directory
# and removing them. ql_rollback_strategy decides from this host's real state, never from its
# name, and --dry-run reports which path a cutover would take. The capture is taken in step 2,
# before any downtime. --suffix applies to the rename path only.
#
# Steps:  1 pre-flight checks (versions, mounts, the SCRAM check above)
#         2 backup: maintenance mode, pg_dump, roles, inspect, the legacy .env
#         3 stop and disable the legacy unit, cold tar of html and PGDATA, save config.php,
#           retire every legacy container (the cron one too: the timer replaces it)
#         4 scripts/install.sh adopts the four directories
#         5 wait for status.php, occ status, leave maintenance mode, tests/smoke.sh
#         6 --rollback when needed
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

LEGACY_UNIT=${LEGACY_UNITS[0]}
LEGACY_ALL=(nextcloud-app nextcloud-cron nextcloud-db nextcloud-redis)
STATE=$APP_STATE_DIR/migration.state

mode=migrate legacy_dir='' bind=0.0.0.0 port='' suffix=$(date +%Y%m%d) fix_db=0 backup_data=0
auto_rollback=1 ASSUME_YES=0
while (($#)); do
  case $1 in
    --legacy-dir) legacy_dir=${2:?--legacy-dir needs a directory}; shift ;;
    --bind) bind=${2:?--bind needs an address}; shift ;;
    --port) port=${2:?--port needs a number}; shift ;;
    --suffix) suffix=${2:?--suffix needs a value}; shift ;;
    --fix-db-password) fix_db=1 ;;
    --backup-data) backup_data=1 ;;
    --prepare-only) mode=prepare ;;
    --dry-run) mode=dry-run ;;
    --no-auto-rollback) auto_rollback=0 ;;
    --rollback) mode=rollback ;;
    --status) mode=status ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,43p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_assert_match --suffix "$suffix" '[A-Za-z0-9._-]+'

state_get() { if [[ -f $STATE ]]; then sed -n "s/^$1=//p" "$STATE" | tail -n1; fi; }
state_set() {
  mkdir -p "$APP_STATE_DIR"
  local tmp
  tmp=$(mktemp "$APP_STATE_DIR/.migration.XXXXXX")
  { if [[ -f $STATE ]]; then grep -v "^$1=" "$STATE" || true; fi; printf '%s=%s\n' "$1" "$2"; } >"$tmp"
  mv -f "$tmp" "$STATE"
}

if [[ $mode == status ]]; then
  if [[ -f $STATE ]]; then cat "$STATE"; else echo "no migration recorded in $STATE"; fi
  exit 0
fi

ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
unit_exists() { [[ -n $(systemctl --user show -p FragmentPath --value "$1" 2>/dev/null) ]]; }

# =============================================================================================
# 6. rollback
# =============================================================================================
rollback() {
  local status sfx c unit_state saved html bk
  local -a renamed=()
  status=$(state_get STATUS) sfx=$(state_get SUFFIX) bk=$(state_get BACKUP)
  read -ra renamed <<<"$(state_get RENAMED)"
  [[ $status == cutover || $status == "done" ]] || ql_die "nothing to roll back (migration status: ${status:-none})"
  app_confirm "--rollback removes the Nextcloud Quadlet units and brings the legacy containers back"
  if app_running "$APP_CONTAINER"; then app_occ maintenance:mode --on >/dev/null 2>&1 || true; fi
  ql_info "stopping and removing the Quadlet units (the data directories are kept)"
  ql_uninstall_units "$APP"
  rm -f -- "$APP_STATE_DIR/env.sha256"
  # The first configuration write of the new stack persisted redis.host=nextcloud-redis into
  # config.php; the legacy stack needs its own copy back.
  saved=$(state_get CONFIG_PHP) html=$(state_get HTML_DIR)
  if [[ -f $saved && -n $html ]]; then
    # Overwrite the existing file rather than copying a host-owned one over it: config.php
    # belongs to the container's www-data, and `cp` without -p leaves the destination's
    # owner and mode alone, which is what Apache needs.
    if podman unshare test -f "$html/config/config.php"; then
      podman unshare cp -- "$saved" "$html/config/config.php" || ql_warn "could not restore config.php from $saved"
      ql_info "restored $html/config/config.php from the copy taken during the cutover"
    else
      ql_warn "$html/config/config.php is gone; put $saved back by hand (owner www-data, mode 0640)"
    fi
  fi
  for c in "${renamed[@]}"; do
    if podman container exists "$c"; then
      [[ $(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c") == nextcloud-*.service ]] \
        || ql_die "container $c exists and is not a Quadlet leftover; resolve it by hand"
      podman rm -f "$c" >/dev/null
    fi
  done
  # renamed back, or recreated from the capture the cutover took - whichever the host needed
  app_legacy_restore "$sfx" "$bk" "${renamed[@]}"
  unit_state=$(state_get LEGACY_UNIT_STATE)
  if unit_exists "$LEGACY_UNIT"; then
    if [[ $unit_state == enabled ]]; then systemctl --user enable "$LEGACY_UNIT" >/dev/null 2>&1; fi
    systemctl --user start "$LEGACY_UNIT"
  else
    podman start "${renamed[@]}" >/dev/null
  fi
  ql_wait_http "http://127.0.0.1:$(state_get LEGACY_PORT)/status.php" '200' 300 \
    || ql_die "the legacy Nextcloud did not answer after the rollback"
  app_occ maintenance:mode --off >/dev/null 2>&1 || ql_warn "run: occ maintenance:mode --off"
  state_set STATUS rolled-back
  ql_info "rolled back: the legacy stack runs again. Backup of the attempt: $(state_get BACKUP)"
}

if [[ $mode == rollback ]]; then
  rollback
  exit 0
fi

# =============================================================================================
# 1. pre-flight checks (read-only)
# =============================================================================================
[[ -n $legacy_dir ]] || ql_die "--legacy-dir is required (the old checkout with its .env)"
legacy_dir=$(cd -- "$legacy_dir" && pwd -P) || ql_die "no such directory: $legacy_dir"
LEGACY_ENV=$legacy_dir/.env
[[ -r $LEGACY_ENV ]] || ql_die "$LEGACY_ENV not found"
legacy_get() {
  local v
  v=$(sed -n "s/^$1=//p" "$LEGACY_ENV" | tail -n1 | tr -d '\r')
  v=${v#\"} v=${v%\"}
  printf '%s' "$v"
}
mount_source() {
  podman inspect --format '{{range .Mounts}}{{.Destination}}|{{.Source}}{{println}}{{end}}' "$1" 2>/dev/null \
    | sed -n "s#^$2|##p" | tail -n1
}

# scram_check: does the password in config.php actually authenticate against the role in
# PostgreSQL? On host networking pg_hba said "trust" for 127.0.0.1, so it was never used.
# Prints "user=<role> mech=<mechanism> match=<true|false|unknown>"; the password is never
# printed and never reaches a command line.
scram_check() {
  command -v python3 >/dev/null 2>&1 || { echo "match=unknown (no python3)"; return 0; }
  python3 - "$APP_CONTAINER" "$DB_CONTAINER" "$DB_USER" "$DB_NAME" <<'PY'
import base64, hashlib, hmac, subprocess, sys
app, db, dbuser, dbname = sys.argv[1:5]
php = 'include "/var/www/html/config/config.php"; echo $CONFIG["dbuser"], "\n", $CONFIG["dbpassword"];'
try:
    out = subprocess.run(["podman", "exec", "-u", "www-data", app, "php", "-r", php],
                         capture_output=True, text=True, check=True).stdout
    user, pw = out.split("\n", 1)
    user = user.strip()
    stored_row = subprocess.run(
        ["podman", "exec", db, "psql", "-U", dbuser, "-d", dbname, "-tAc",
         "select rolpassword from pg_authid where rolname = '%s'" % user.replace("'", "''")],
        capture_output=True, text=True, check=True).stdout.strip()
    if not stored_row:
        print("user=%s match=unknown (no such role)" % user); sys.exit(0)
    if not stored_row.startswith("SCRAM-SHA-256$"):
        print("user=%s mech=%s match=unknown (not SCRAM)" % (user, stored_row.split("$")[0])); sys.exit(0)
    mech, rest = stored_row.split("$", 1)
    itsalt, keys = rest.split("$")
    iterations, salt = itsalt.split(":")
    stored_key = keys.split(":")[0]
    salted = hashlib.pbkdf2_hmac("sha256", pw.encode(), base64.b64decode(salt), int(iterations))
    client_key = hmac.new(salted, b"Client Key", "sha256").digest()
    match = base64.b64encode(hashlib.sha256(client_key).digest()).decode() == stored_key
    print("user=%s mech=%s match=%s" % (user, mech, str(match).lower()))
except Exception as exc:
    print("match=unknown (%s)" % exc.__class__.__name__)
PY
}

# fix_db_password: set the role's password to the one config.php uses. Idempotent, and the
# password never appears in a command line or in the shell history.
fix_db_password() {
  local user
  user=$(podman exec -u www-data "$APP_CONTAINER" php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["dbuser"];' | tr -d '\r\n')
  [[ -n $user ]] || ql_die "cannot read dbuser from config.php"
  podman exec -u www-data "$APP_CONTAINER" php -r 'include "/var/www/html/config/config.php"; echo $CONFIG["dbpassword"];' \
    | podman exec -i "$DB_CONTAINER" sh -c "IFS= read -r p || true
      case \$p in *'\$pw\$'*) echo 'the password contains the dollar-quote marker; set it by hand' >&2; exit 3 ;; esac
      printf 'ALTER ROLE \"%s\" PASSWORD \$pw\$%s\$pw\$;\n' '$user' \"\$p\" | psql -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1 -q" \
    || ql_die "ALTER ROLE $user failed"
  ql_info "set the password of the database role $user to the one in config.php"
}

ql_info "step 1/5: pre-flight checks"
case $(state_get STATUS) in
  cutover | "done") ql_die "a cutover is already recorded in $STATE (use --status, or --rollback)" ;;
esac
if [[ $mode == dry-run ]]; then QL_DRY_RUN=1 ql_enable_linger; else ql_enable_linger; fi
legacy_containers=()
for c in "${LEGACY_ALL[@]}"; do
  if podman container exists "$c"; then legacy_containers+=("$c"); fi
done
for c in "$APP_CONTAINER" "$DB_CONTAINER" "$REDIS_CONTAINER"; do
  podman container exists "$c" || ql_die "legacy container $c not found"
  label=$(podman inspect --format '{{index .Config.Labels "PODMAN_SYSTEMD_UNIT"}}' "$c")
  [[ $label != nextcloud-*.service ]] || ql_die "$c is already managed by Quadlet ($label)"
  app_running "$c" || ql_die "legacy container $c is not running; start the legacy stack first"
done
# How the legacy containers are kept for --rollback: renamed and left stopped, or captured
# and removed. Asked of this host, never of its name (STANDARD 7a, quadlet-lib >= 1.4.0).
# The compose-era Nextcloud containers carry restart=always, so on a host whose
# podman-restart.service is enabled a renamed copy would revive at boot and a second
# PostgreSQL and a second Apache would open the same data directories.
STRATEGY=$(ql_rollback_strategy "${legacy_containers[@]}")
if [[ $STRATEGY == rename ]]; then
  for c in "${legacy_containers[@]}"; do
    if podman container exists "$c-legacy-$suffix"; then ql_die "$c-legacy-$suffix already exists; pick another --suffix"; fi
  done
fi
legacy_html=$(mount_source "$APP_CONTAINER" /var/www/html)
legacy_data=$(mount_source "$APP_CONTAINER" /var/www/html/data)
legacy_pgdata=$(mount_source "$DB_CONTAINER" /var/lib/postgresql/data)
legacy_redis=$(mount_source "$REDIS_CONTAINER" /data)
for d in "$legacy_html" "$legacy_data" "$legacy_pgdata" "$legacy_redis"; do
  [[ -d $d ]] || ql_die "could not read every bind mount from podman inspect (html='$legacy_html' data='$legacy_data' pgdata='$legacy_pgdata' redis='$legacy_redis')"
done
[[ $(legacy_get POSTGRES_USER) == "$DB_USER" && $(legacy_get POSTGRES_DB) == "$DB_NAME" ]] \
  || ql_die "the legacy .env must use POSTGRES_USER=$DB_USER and POSTGRES_DB=$DB_NAME (the units fix them)"
[[ -n $(legacy_get POSTGRES_PASSWORD) ]] || ql_die "POSTGRES_PASSWORD is empty in $LEGACY_ENV"
port=${port:-$(legacy_get NEXTCLOUD_PORT)}
port=${port:-18080}
ql_assert_match "the publish port" "$port" '[0-9]{1,5}'
cur=$(app_installed_version)
tgt=$(app_image_version "$APP_IMAGE")
if [[ -z $tgt ]]; then
  ql_info "pulling $APP_IMAGE to read its version"
  podman pull "$APP_IMAGE" >/dev/null || ql_die "podman pull $APP_IMAGE failed"
  tgt=$(app_image_version "$APP_IMAGE")
fi
[[ -n $cur && $cur == "$tgt" ]] \
  || ql_die "the legacy Nextcloud runs '${cur:-?}' but this checkout pins $tgt; migrate at the same version, then upgrade"
pg_cur=$(app_pg_major_running)
pg_tgt=$(app_pg_major_image "$DB_IMAGE")
[[ -z $pg_cur || -z $pg_tgt || $pg_cur == "$pg_tgt" ]] \
  || ql_die "the legacy PostgreSQL is major $pg_cur, the pin is $pg_tgt; that needs a dump and restore, not a migration"
if app_is_installed && [[ $(state_get STATUS) != prepared ]]; then
  ql_die "the Nextcloud Quadlet units are already installed; this host needs no migration"
fi
if unit_exists "$LEGACY_UNIT"; then
  ql_info "legacy unit $LEGACY_UNIT: $(systemctl --user is-enabled "$LEGACY_UNIT" 2>/dev/null || true)"
else
  ql_warn "no $LEGACY_UNIT on this host; the legacy containers will be stopped with podman stop"
fi
ql_info "legacy Nextcloud $cur on port $port, containers: ${legacy_containers[*]}"
ql_info "html: $legacy_html"
ql_info "data: $legacy_data"
ql_info "db:   $legacy_pgdata"
ql_info "redis: $legacy_redis"

scram=$(scram_check)
ql_info "database password check: $scram"
if [[ $scram == *match=false* ]]; then
  if ((fix_db)); then
    fix_db_password
    scram=$(scram_check)
    ql_info "database password check: $scram"
    [[ $scram == *match=true* ]] || ql_die "the password in config.php still does not match the role"
  else
    ql_die "config.php's database password does NOT authenticate against the role. On the bridge network that password is finally used, so the app would fail to start. Re-run with --fix-db-password (it sets the role's password to the one config.php already uses)"
  fi
elif [[ $scram == *match=unknown* ]]; then
  ql_warn "could not verify the database password; if the app cannot connect after the cutover, re-run with --fix-db-password or roll back"
fi

derive_env() {
  local f=$1 k v
  ql_env_set "$f" HOST_BIND "$bind"
  ql_env_set "$f" HOST_PORT "$port"
  ql_env_set "$f" HOST_HTML_DIR "$(app_spec_path "$legacy_html")"
  ql_env_set "$f" HOST_DATA_DIR "$(app_spec_path "$legacy_data")"
  ql_env_set "$f" HOST_POSTGRES_DIR "$(app_spec_path "$legacy_pgdata")"
  ql_env_set "$f" HOST_REDIS_DIR "$(app_spec_path "$legacy_redis")"
  for k in NEXTCLOUD_ADMIN_USER NEXTCLOUD_TRUSTED_DOMAINS OVERWRITEPROTOCOL OVERWRITECLIURL \
    TRUSTED_PROXIES PHP_MEMORY_LIMIT PHP_UPLOAD_LIMIT; do
    v=$(legacy_get "$k")
    [[ -z $v ]] || ql_env_set "$f" "$k" "$v"
  done
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-migrate.XXXXXX")
ql_cleanup work rm -rf "$WORK"
if [[ $mode == dry-run ]]; then
  if [[ -f $ENV_FILE ]]; then cp -p -- "$ENV_FILE" "$WORK/nextcloud.env"; else install -m 600 -- "$ENV_EXAMPLE" "$WORK/nextcloud.env"; fi
  derive_env "$WORK/nextcloud.env"
  ql_env_load "$WORK/nextcloud.env"
  app_validate_env
  app_render "$WORK/render" "$WORK/nextcloud.env"
  if [[ $STRATEGY == capture ]]; then
    ql_info "dry-run: checks passed and the units render. The cutover would stop $LEGACY_UNIT, capture ${legacy_containers[*]} into the backup directory and remove them (podman-restart.service would revive a renamed copy here), and install:"
  else
    ql_info "dry-run: checks passed and the units render. The cutover would stop $LEGACY_UNIT, rename ${legacy_containers[*]} to *-legacy-$suffix and install:"
  fi
  sed 's/^/    /' < <(grep -vE '^[[:space:]]*(#|$)' "$WORK/nextcloud.env") >&2
  exit 0
fi

# =============================================================================================
# 2. prepare (no downtime): env file, secrets, images, hot backup
# =============================================================================================
ql_info "step 2/5: env file, secrets, images and a hot backup (no downtime)"
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
[[ $QL_ENV_CREATED != 1 ]] || ql_info "filling $ENV_FILE in from $LEGACY_ENV (review it after the cutover)"
derive_env "$ENV_FILE"
ql_env_load "$ENV_FILE"
app_validate_env
# shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_DB_PASSWORD
LEGACY_DB_PASSWORD=$(legacy_get POSTGRES_PASSWORD)
ql_secret_ensure "$SECRET_DB" env:LEGACY_DB_PASSWORD --update
unset LEGACY_DB_PASSWORD
# shellcheck disable=SC2034 # read by ql_secret_ensure through env:LEGACY_ADMIN_PASSWORD
LEGACY_ADMIN_PASSWORD=$(legacy_get NEXTCLOUD_ADMIN_PASSWORD)
if [[ -n $LEGACY_ADMIN_PASSWORD ]]; then
  ql_secret_ensure "$SECRET_ADMIN" env:LEGACY_ADMIN_PASSWORD --update
else
  ql_secret_ensure "$SECRET_ADMIN" random:24
fi
unset LEGACY_ADMIN_PASSWORD
app_render "$WORK/render" "$ENV_FILE"
ql_pull_images "$WORK/render/out"

bk=$(state_get BACKUP)
if [[ $(state_get STATUS) != prepared || ! -d $bk ]]; then
  bk=$(app_new_backup_dir "$BACKUP_ROOT/migrate-$(date +%Y%m%d-%H%M%S)")
fi
(umask 077 && cp -p -- "$LEGACY_ENV" "$bk/legacy.env")
mkdir -p "$bk/secrets"
for s in "$SECRET_DB" "$SECRET_ADMIN"; do
  if podman secret exists "$s"; then app_save_secret "$s" "$bk/secrets/$s"; fi
done
if unit_exists "$LEGACY_UNIT"; then systemctl --user cat "$LEGACY_UNIT" >"$bk/$LEGACY_UNIT" 2>/dev/null || true; fi
podman inspect "${legacy_containers[@]}" >"$bk/inspect.json"
{
  printf 'legacy version: %s\n' "$cur"
  printf 'html: %s\ndata: %s\npgdata: %s\nredis: %s\n' "$legacy_html" "$legacy_data" "$legacy_pgdata" "$legacy_redis"
  printf 'db password check: %s\n' "$scram"
  app_occ status --output=json 2>/dev/null || true
  app_occ user:list 2>/dev/null || true
  app_occ config:app:get core backgroundjobs_mode 2>/dev/null || true
  podman exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select 'oc_filecache=' || count(*) from oc_filecache" 2>/dev/null || true
  podman exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "select extname || ' ' || extversion from pg_extension order by 1" 2>/dev/null || true
} >"$bk/precheck.txt"
app_occ app:list --output=json >"$bk/apps.pre.json" 2>/dev/null || true
ql_info "pre-migration state saved in $bk/precheck.txt"
app_write_checksums "$bk"
state_set STATUS prepared
state_set BACKUP "$bk"
state_set SUFFIX "$suffix"
state_set LEGACY_PORT "$port"
state_set HTML_DIR "$legacy_html"
state_set RENAMED "${legacy_containers[*]}"
# On the capture path the rollback copy is written now, while the legacy stack still runs:
# a container whose create command cannot be replayed is then refused before any downtime.
if [[ $STRATEGY == capture ]]; then
  app_legacy_capture "$bk" "${legacy_containers[@]}"
  app_write_checksums "$bk"
fi
state_set STRATEGY "$STRATEGY"
if [[ $mode == prepare ]]; then
  ql_info "prepared. Run the cutover (8-12 min of maintenance mode) with the same options minus --prepare-only"
  exit 0
fi

# =============================================================================================
# 3. maintenance mode, dump, stop, cold tar, save config.php, rename (downtime starts)
# =============================================================================================
app_confirm "the cutover puts Nextcloud into maintenance mode for about 8-12 minutes"
ql_info "step 3/5: maintenance mode, database dump, stop, cold copies, retiring the legacy containers ($STRATEGY)"
state_set STATUS cutover
app_maintenance on
app_dump_db "$bk/nextcloud.pgdump"
app_dump_roles "$bk/roles.sql"
unit_state=$(systemctl --user is-enabled "$LEGACY_UNIT" 2>/dev/null || true)
state_set LEGACY_UNIT_STATE "${unit_state:-absent}"
if unit_exists "$LEGACY_UNIT"; then
  systemctl --user disable "$LEGACY_UNIT" >/dev/null 2>&1 || true
  systemctl --user stop "$LEGACY_UNIT" || true
  ! systemctl --user is-active --quiet "$LEGACY_UNIT" || ql_die "$LEGACY_UNIT is still active"
  ql_info "disabled and stopped $LEGACY_UNIT (the unit file stays for --rollback)"
fi
for c in "${legacy_containers[@]}"; do
  if app_running "$c"; then podman stop -t 60 "$c" >/dev/null; fi
  ! app_running "$c" || ql_die "$c is still running"
done
ql_backup_dir "$legacy_html" "$bk/html.tgz" --exclude "$(basename -- "$legacy_html")/data" >/dev/null
ql_backup_dir "$legacy_pgdata" "$bk/postgres-dir.tgz" >/dev/null
((!backup_data)) || ql_backup_dir "$legacy_data" "$bk/data.tgz" >/dev/null
# The first configuration write of the new stack persists redis.host=nextcloud-redis into
# config.php, so keep the current one for the rollback. Copy the CONTENT into a file the
# host user owns: `cp -p` would keep the www-data subuid ownership, and then neither the
# 0600 chmod below nor app_write_checksums could touch the file.
(umask 077 && podman unshare cat -- "$legacy_html/config/config.php" >"$bk/config.php.pre-quadlet") \
  || ql_die "cannot copy config.php"
state_set CONFIG_PHP "$bk/config.php.pre-quadlet"
app_legacy_retire "$STRATEGY" "$suffix" "$bk" "${legacy_containers[@]}"
app_write_checksums "$bk"

# =============================================================================================
# 4. install    5. wait, check, leave maintenance mode, smoke
# =============================================================================================
ql_info "step 4/5: scripts/install.sh"
failed=0
"$REPO/scripts/install.sh" --no-smoke || failed=1
if ((!failed)); then
  ql_info "step 5/5: waiting for status.php, then the checks"
  app_wait_status 900 "$cur" || failed=1
fi
if ((!failed)); then
  if app_occ status >/dev/null 2>&1; then
    ql_info "occ status works: oc_admin authenticates over the bridge"
  else
    ql_warn "occ status failed: the database password does not authenticate (see --fix-db-password)"
    failed=1
  fi
fi
if ((!failed)); then
  ql_info "dbhost: $(app_occ config:system:get dbhost 2>/dev/null | tr -d '\r\n')"
  app_occ maintenance:mode --off >/dev/null || failed=1
  "$REPO/tests/smoke.sh" --timeout 900 || failed=1
fi
if ((failed)); then
  if ((auto_rollback)); then
    ql_warn "the cutover failed; rolling back automatically (--no-auto-rollback keeps it for inspection)"
    ASSUME_YES=1 rollback
    ql_die "migration failed and was rolled back; the legacy stack runs again. Logs: journalctl --user -u nextcloud-app.service"
  fi
  ql_die "the cutover failed; the new units are left in place. Inspect, then run: $0 --rollback"
fi
state_set STATUS "done"
ql_info "migration complete. Compare with $bk/precheck.txt (users, oc_filecache, apps, extensions)."
ql_info "the database and Redis are no longer on the host loopback; verify with: ss -ltnH '( sport = :5432 or sport = :6379 )'"
if [[ $STRATEGY == capture ]]; then
  ql_info "the legacy containers were captured into $bk/legacy-container and removed (podman-restart.service is enabled here, so a renamed copy would have revived at boot); $LEGACY_UNIT is disabled. Roll back with:"
else
  ql_info "legacy containers *-legacy-$suffix and $LEGACY_UNIT (disabled) are kept for rollback:"
fi
ql_info "  $0 --rollback"
ql_info "after the soak period, clean up as described in README ('After the soak')"
