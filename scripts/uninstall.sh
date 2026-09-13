#!/usr/bin/env bash
# scripts/uninstall.sh: remove the Nextcloud Quadlet units and the cron timer. Keeps every
# piece of data by default.
#
#   scripts/uninstall.sh                   stop and remove the units; keep the html, data,
#                                          database and Redis directories, the secrets, the
#                                          network and ~/.config/nextcloud/nextcloud.env
#   scripts/uninstall.sh --purge [--yes]   also delete the network and the secrets (both
#                                          secrets are exported first)
#   scripts/uninstall.sh --dry-run         report what would be removed
#
# --purge is the only way this repo deletes anything, and it NEVER deletes the bind-mounted
# directories: it prints the commands for that, so a mistyped path cannot destroy user files.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

purge=0 ASSUME_YES=0
while (($#)); do
  case $1 in
    --purge) purge=1 ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,14p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_require_rootless
ql_lock "$APP"
dirs=()
if [[ -f $ENV_FILE ]]; then
  ql_env_load "$ENV_FILE"
  for k in "${DATA_DIR_KEYS[@]}"; do dirs+=("$(app_dir "$k")"); done
fi

if ((!purge)); then
  ql_uninstall_units "$APP"
  [[ ${QL_DRY_RUN:-0} == 1 ]] || rm -f -- "$APP_STATE_DIR/env.sha256"
  ql_info "kept: ${dirs[*]:-the data directories}, the secrets and $ENV_FILE"
  exit 0
fi

app_confirm "--purge deletes the nextcloud-network and the podman secrets (the database and admin passwords)"
if [[ ${QL_DRY_RUN:-0} != 1 ]]; then
  systemctl --user stop "$TARGET" nextcloud-cron.timer nextcloud-app.service \
    nextcloud-redis.service nextcloud-db.service 2>/dev/null || true
  dest=$(app_new_backup_dir "$BACKUP_ROOT/purge-$(date +%Y%m%d-%H%M%S)")
  mkdir -p "$dest/secrets"
  for s in "$SECRET_DB" "$SECRET_ADMIN"; do
    if podman secret exists "$s"; then app_save_secret "$s" "$dest/secrets/$s"; fi
  done
  [[ ! -f $ENV_FILE ]] || cp -p -- "$ENV_FILE" "$dest/"
  app_write_checksums "$dest"
  ql_info "kept the passwords and the env file in $dest"
fi
ql_uninstall_units "$APP" --purge
ql_info "the Nextcloud directories are UNTOUCHED. Delete them yourself if you want to:"
for d in "${dirs[@]}"; do ql_info "  podman unshare rm -rf $d"; done
ql_info "  rm -rf ${ENV_FILE%/*}"
