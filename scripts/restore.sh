#!/usr/bin/env bash
# scripts/restore.sh: put a scripts/backup.sh backup back into the installed stack.
#
#   scripts/restore.sh <backup-dir> [--with-html] [--yes]
#
# 1. verifies SHA256SUMS
# 2. stops the cron timer and the app (PostgreSQL keeps running)
# 3. restores the secrets and the roles, then the database (pg_restore --clean --create):
#    the role password hashes and the secrets travel together, so config.php's oc_admin
#    password still authenticates afterwards
# 4. restores config.tgz (and data.tgz when it is in the backup); --with-html also replaces
#    the whole html directory from a --cold backup, which is what a version rollback needs
# 5. starts the app, refreshes the data fingerprint, leaves maintenance mode and smokes
#
# Unlike the old scripts/restore.sh this never calls `podman stop` behind systemd's back,
# and it does not chown anything: the archives carry the numeric owners.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

src='' with_html=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --with-html) with_html=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) ql_die "unknown option $1 (see --help)" ;;
    *) [[ -z $src ]] || ql_die "one backup directory only"; src=$1 ;;
  esac
  shift
done
[[ -n $src ]] || ql_die "usage: scripts/restore.sh <backup-dir> [--with-html] [--yes]"
src=$(cd -- "$src" && pwd -P) || ql_die "no such directory: $src"
ql_require_rootless
ql_lock "$APP"
app_require_installed
ql_env_load "$ENV_FILE"
html_dir=$(app_dir HOST_HTML_DIR)
data_dir=$(app_dir HOST_DATA_DIR)

[[ -f $src/SHA256SUMS ]] || ql_die "$src/SHA256SUMS is missing: not a scripts/backup.sh backup"
(cd -- "$src" && sha256sum -c --quiet SHA256SUMS) || ql_die "checksum mismatch in $src"
[[ -f $src/nextcloud.pgdump ]] || ql_die "$src/nextcloud.pgdump is missing"
((!with_html)) || [[ -f $src/html.tgz ]] || ql_die "--with-html needs html.tgz (a --cold backup)"
app_confirm "restore replaces the Nextcloud database and configuration with $src"

ts=$(date +%Y%m%d-%H%M%S)
ql_info "stopping the cron timer and the app (PostgreSQL keeps running)"
systemctl --user stop nextcloud-cron.timer nextcloud-app.service
systemctl --user start nextcloud-db.service
QL_HEALTH_ACTIVE=1 ql_wait_container_healthy "$DB_CONTAINER" 300 || ql_die "$DB_CONTAINER is not healthy"

for f in "$src"/secrets/*; do
  [[ -f $f ]] || continue
  ql_secret_ensure "${f##*/}" "file:$f" --update
done
[[ ! -f $src/roles.sql ]] || app_restore_roles "$src/roles.sql"
app_restore_db "$src/nextcloud.pgdump"

if ((with_html)); then
  app_replace_dir "$html_dir" "$src/html.tgz" "pre-restore-$ts"
fi
[[ ! -f $src/config.tgz ]] || app_replace_dir "$html_dir/config" "$src/config.tgz" "pre-restore-$ts"
[[ ! -f $src/data.tgz ]] || app_replace_dir "$data_dir" "$src/data.tgz" "pre-restore-$ts"

mapfile -t units < <(app_units)
systemctl --user start "${units[@]}"
app_wait_status 900 || ql_die "Nextcloud did not come back; see: journalctl --user -u nextcloud-app.service -n 100"
app_occ maintenance:data-fingerprint >/dev/null || ql_warn "occ maintenance:data-fingerprint failed"
app_occ maintenance:mode --off >/dev/null || ql_warn "could not leave maintenance mode"
"$REPO/tests/smoke.sh" --timeout 900 || ql_die "restored, but the smoke test failed"
ql_info "restore of $src complete"
ql_info "the replaced directories are kept as *.pre-restore-$ts; remove them with podman unshare rm -rf when you are satisfied"
