#!/usr/bin/env bash
# scripts/upgrade.sh: move the installed Nextcloud to the version pinned in this checkout.
# The repo is the source of truth: an upgrade is `git pull` (a commit that bumps Image=),
# then this script.
#
#   scripts/upgrade.sh [--repair] [--yes]
#
# backup -> pull -> restart -> smoke -> automatic rollback:
#  1. gates, before anything stops: no downgrade, and ONE major version at a time. The
#     image's entrypoint enforces the same rule, but by then the old container is gone, so
#     this script checks first and refuses to start the upgrade at all.
#  2. pulls the image (also to read its NEXTCLOUD_VERSION) and refuses a PostgreSQL major change
#  3. maintenance mode on, scripts/backup.sh --cold --no-data into
#     ~/backups/nextcloud/upgrade-<timestamp>/: the dump, the roles, config, the html
#     directory and the database directory. The user files are not touched by an upgrade.
#  4. installs the new unit and starts it; the entrypoint rsyncs the release and runs
#     `occ upgrade`, so it polls status.php for up to 30 minutes instead of trusting a
#     start timeout. Then the post-upgrade occ tasks and tests/smoke.sh.
#  5. on failure: stop, put the previous units, html directory and database directory back,
#     start, leave maintenance mode, smoke, exit 1
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

repair=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --repair) repair=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_preflight "$PODMAN_MIN"
ql_lock "$APP"
app_require_installed
ql_env_load "$ENV_FILE"
app_validate_env
html_dir=$(app_dir HOST_HTML_DIR)
postgres_dir=$(app_dir HOST_POSTGRES_DIR)

# ---- 1. and 2. gates --------------------------------------------------------------------------
ql_info "pulling $APP_IMAGE"
podman image exists "$APP_IMAGE" || podman pull "$APP_IMAGE" >/dev/null || ql_die "podman pull $APP_IMAGE failed; nothing was changed"
for i in "$DB_IMAGE" "$REDIS_IMAGE"; do
  podman image exists "$i" || podman pull "$i" >/dev/null || ql_die "podman pull $i failed; nothing was changed"
done
tgt=$(app_image_version "$APP_IMAGE")
[[ -n $tgt ]] || ql_die "cannot read NEXTCLOUD_VERSION from $APP_IMAGE"
cur=$(app_installed_version)
[[ -n $cur ]] || ql_die "cannot read the installed version (is nextcloud-app running?)"
if [[ $cur == "$tgt" ]]; then
  ql_info "Nextcloud is already at $tgt; applying unit changes only"
  version_change=0
else
  [[ $(printf '%s\n%s\n' "$cur" "$tgt" | sort -V | head -n1) == "$cur" ]] \
    || ql_die "downgrade $cur -> $tgt is not supported by Nextcloud; restore a backup instead"
  ((10#${tgt%%.*} <= 10#${cur%%.*} + 1)) \
    || ql_die "one major version at a time: $cur -> $tgt skips $((10#${cur%%.*} + 1)); pin the latest $((10#${cur%%.*} + 1)).x-apache image first"
  version_change=1
fi
pg_cur=$(app_pg_major_running)
pg_tgt=$(app_pg_major_image "$DB_IMAGE")
if [[ -n $pg_cur && -n $pg_tgt && $pg_cur != "$pg_tgt" ]]; then
  ql_die "the database image moves from PostgreSQL $pg_cur to $pg_tgt; dump and restore instead (README: PostgreSQL major upgrade)"
fi
if ((version_change)); then
  ql_info "apps that are not shipped with Nextcloud (check their compatibility with $tgt):"
  app_occ app:list --shipped=false 2>/dev/null | sed 's/^/    /' || true
  app_confirm "upgrade Nextcloud $cur -> $tgt (a cold backup is taken first; failure rolls back automatically)"
fi

# ---- 3. cold backup with maintenance mode on -------------------------------------------------------
bk=$("$REPO/scripts/backup.sh" --cold --no-data --dest "$BACKUP_ROOT/upgrade-$(date +%Y%m%d-%H%M%S)" | tail -n1)
[[ -f $bk/nextcloud.pgdump && -f $bk/html.tgz && -f $bk/postgres-dir.tgz && -d $bk/units ]] \
  || ql_die "the pre-upgrade backup is incomplete ($bk); nothing was changed"

# ---- 4. install, wait for the entrypoint, post-upgrade tasks ----------------------------------------
ts=$(date +%Y%m%d-%H%M%S)
ok=1
if ! "$REPO/scripts/install.sh" --no-start --no-smoke; then
  ql_warn "install.sh failed before anything restarted; putting the previous units back"
  ql_install_files "$bk/units" "$APP" --prune >/dev/null
  systemctl --user daemon-reload
  ql_die "upgrade aborted; the stack still runs $cur (backup: $bk)"
fi
# Best effort: the entrypoint turns maintenance mode on itself before `occ upgrade`, and a
# failure here must not abort the upgrade (app_maintenance exits the script, so `|| true`
# around it would not help).
app_occ maintenance:mode --on >/dev/null 2>&1 || ql_warn "could not switch maintenance mode on before the restart; the entrypoint does it too"
mapfile -t units < <(app_units)
systemctl --user restart nextcloud-app.service || ok=0
if ((ok)); then
  ql_info "waiting for the entrypoint to rsync $tgt and run occ upgrade (up to 30 min)"
  app_wait_status 1800 "$tgt" || ok=0
fi
if ((ok)); then
  app_occ maintenance:mode --off >/dev/null || ok=0
  app_occ db:add-missing-indices >/dev/null || ql_warn "occ db:add-missing-indices failed"
  app_occ db:add-missing-columns >/dev/null || ql_warn "occ db:add-missing-columns failed"
  app_occ db:add-missing-primary-keys >/dev/null || ql_warn "occ db:add-missing-primary-keys failed"
  app_occ app:update --all >/dev/null || ql_warn "occ app:update --all failed"
  ((!repair)) || app_occ maintenance:repair --include-expensive >/dev/null || ql_warn "occ maintenance:repair failed"
  ql_apply_units "$APP" "${units[@]}"
  app_env_record
  "$REPO/tests/smoke.sh" --timeout 900 || ok=0
fi
if ((ok)); then
  ql_info "upgrade to $tgt complete (pre-upgrade backup: $bk)"
  exit 0
fi

# ---- 5. automatic rollback ---------------------------------------------------------------------
# rollback_incomplete: say so if this script ends before the rollback below finishes.
# A hook, not `trap ... EXIT`: a bare trap would replace the handler ql_lock armed and
# leave the lock directory behind, so every later run would report a takeover.
# shellcheck disable=SC2329 # invoked indirectly, as the ql_cleanup hook registered below
rollback_incomplete() {
  local rc=$?
  ((rc == 0)) || ql_warn "ROLLBACK INCOMPLETE (rc=$rc). Backup: $bk. Restore by hand: scripts/restore.sh $bk --with-html"
}
ql_cleanup rollback rollback_incomplete
ql_warn "upgrade to $tgt failed; rolling back to $cur"
systemctl --user stop "${units[@]}" || true
ql_install_files "$bk/units" "$APP" --prune >/dev/null
if ((version_change)); then
  # Nextcloud cannot downgrade: the code in the html directory and the database have to go
  # back together, which is why the backup is taken cold.
  app_replace_dir "$html_dir" "$bk/html.tgz" "failed-$tgt-$ts"
  app_replace_dir "$postgres_dir" "$bk/postgres-dir.tgz" "failed-$tgt-$ts"
fi
ql_apply_units "$APP" "${units[@]}"
app_env_record
app_wait_status 900 || ql_die "the rolled-back Nextcloud did not come back"
app_occ maintenance:mode --off >/dev/null || ql_warn "could not leave maintenance mode"
"$REPO/tests/smoke.sh" --timeout 900 || ql_die "the rolled-back stack failed its smoke test"
ql_cleanup_clear rollback
ql_warn "rolled back to $cur; the upgrade to $tgt did not pass (backup: $bk)"
((!version_change)) || ql_warn "the failed attempt is kept as $html_dir.failed-$tgt-$ts and $postgres_dir.failed-$tgt-$ts"
exit 1
