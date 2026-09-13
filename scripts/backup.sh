#!/usr/bin/env bash
# scripts/backup.sh: back up Nextcloud into a private (0700) directory.
#
#   scripts/backup.sh [--dest DIR] [--cold] [--no-data]
#
#   (default)   maintenance mode on, then:
#                 nextcloud.pgdump  pg_dump -Fc of the nextcloud database
#                 roles.sql         the roles with their password hashes (config.php
#                                   authenticates as oc_admin, which pg_dump does not carry)
#                 config.tgz        the config directory inside the html directory
#                 data.tgz          the user files (skip with --no-data)
#                 secrets/, nextcloud.env, units/, versions.txt, SHA256SUMS
#               maintenance mode off again (also on failure, through a trap)
#   --cold      also stop the stack and archive the html directory (Nextcloud's code and
#               apps) and the PostgreSQL directory byte for byte, then start it again
#   --no-data   skip the user files, for an instance whose data is backed up by other means
#
# Unlike the old scripts/backup.sh, a failing `occ maintenance:mode --on` aborts the backup
# instead of being swallowed by `|| true`, and everything runs as www-data.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

dest='' cold=0 no_data=0
while (($#)); do
  case $1 in
    --dest) dest=${2:?--dest needs a directory}; shift ;;
    --cold) cold=1 ;;
    --no-data) no_data=1 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
ql_env_load "$ENV_FILE"
app_running "$APP_CONTAINER" || ql_die "$APP_CONTAINER is not running (start it: systemctl --user start $TARGET)"
app_running "$DB_CONTAINER" || ql_die "$DB_CONTAINER is not running"
html_dir=$(app_dir HOST_HTML_DIR)
data_dir=$(app_dir HOST_DATA_DIR)
postgres_dir=$(app_dir HOST_POSTGRES_DIR)

dest=$(app_new_backup_dir "$dest")
ql_info "backing up $APP to $dest"

maint=0 stopped=0
finish() {
  local rc=$?
  if ((stopped)); then
    systemctl --user start "$TARGET" || ql_warn "could not start $TARGET again"
    app_wait_status 900 || ql_warn "Nextcloud did not come back; check it before leaving"
    stopped=0
  fi
  if ((maint)); then
    app_occ maintenance:mode --off >/dev/null 2>&1 || ql_warn "could not switch maintenance mode off: occ maintenance:mode --off"
    maint=0
  fi
  return $rc
}
# a hook, not `trap ... EXIT`, which would replace the handler ql_lock armed
ql_cleanup finish finish

app_maintenance on
maint=1
app_dump_db "$dest/nextcloud.pgdump"
app_dump_roles "$dest/roles.sql"
if [[ -d $html_dir/config ]]; then
  ql_backup_dir "$html_dir/config" "$dest/config.tgz" >/dev/null
else
  ql_warn "$html_dir/config does not exist yet; the backup has no config.tgz"
fi
((no_data)) || ql_backup_dir "$data_dir" "$dest/data.tgz" >/dev/null
mkdir -p "$dest/secrets"
for s in "$SECRET_DB" "$SECRET_ADMIN"; do
  if podman secret exists "$s"; then app_save_secret "$s" "$dest/secrets/$s"; fi
done
[[ ! -f $ENV_FILE ]] || cp -p -- "$ENV_FILE" "$dest/"
if app_is_installed; then app_snapshot_units "$dest/units"; fi
{
  printf 'nextcloud version: %s\n' "$(app_installed_version)"
  printf 'image: %s\n' "$(app_installed_image nextcloud-app.container)"
  printf 'html: %s\ndata: %s\npostgres: %s\n' "$html_dir" "$data_dir" "$postgres_dir"
  app_occ status 2>/dev/null || true
} >"$dest/versions.txt"

if ((cold)); then
  ql_info "stopping $TARGET for the cold copy of the html and database directories"
  mapfile -t units < <(app_units)
  systemctl --user stop "${units[@]}"
  stopped=1
  ql_backup_dir "$html_dir" "$dest/html.tgz" --exclude "$(basename -- "$html_dir")/data" >/dev/null
  ql_backup_dir "$postgres_dir" "$dest/postgres-dir.tgz" >/dev/null
  systemctl --user start "$TARGET"
  stopped=0
  app_wait_status 900 || ql_warn "Nextcloud did not come back within 900s"
fi

app_write_checksums "$dest"
ql_cleanup_clear finish
finish
ql_info "backup complete: $dest ($(du -sh -- "$dest" | cut -f1))"
printf '%s\n' "$dest"
