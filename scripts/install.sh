#!/usr/bin/env bash
# scripts/install.sh: install or update Nextcloud as rootless Quadlet units (podman 4.9.3,
# systemd --user, linger). Idempotent: a re-run with nothing changed restarts nothing.
#
#   scripts/install.sh [--db-password-file F] [--admin-password-file F] [--no-start]
#                      [--no-smoke] [--smoke-timeout S] [--dry-run]
#
#   --db-password-file F      first install only: the PostgreSQL password comes from F
#   --admin-password-file F   first install only: the Nextcloud admin password comes from F
#   --no-start                install the files and daemon-reload only
#   --no-smoke                skip tests/smoke.sh at the end
#   --smoke-timeout S         seconds to wait for Nextcloud (default 900: the entrypoint
#                             rsyncs the release and may run occ upgrade)
#   --dry-run                 render and validate, report what would change; change nothing
#
# On a fresh install (no config/config.php in the html directory yet) it also enables the
# cron background-job mode, creates the pgvector extension and adds the missing database
# indices once Nextcloud is up.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"

db_pw_file='' admin_pw_file='' no_start=0 no_smoke=0 smoke_timeout=900
while (($#)); do
  case $1 in
    --db-password-file) db_pw_file=${2:?--db-password-file needs a file}; shift ;;
    --admin-password-file) admin_pw_file=${2:?--admin-password-file needs a file}; shift ;;
    --no-start) no_start=1 ;;
    --no-smoke) no_smoke=1 ;;
    --smoke-timeout) smoke_timeout=${2:?--smoke-timeout needs seconds}; shift ;;
    --dry-run) export QL_DRY_RUN=1 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
dry=${QL_DRY_RUN:-0}

# ---- 1. host preflight ----------------------------------------------------------------------
ql_preflight "$PODMAN_MIN"
ql_enable_linger
# upgrade.sh and migrate-legacy.sh hold the lock already and call this script.
[[ ${WOOW_QL_LOCK_HELD:-} == "$APP" ]] || ql_lock "$APP"

# ---- 2. per-host settings (D2: values come from the env file, never from the repo) ---------
ql_env_ensure "$ENV_EXAMPLE" "$ENV_FILE"
render_env=$ENV_FILE
if [[ ! -f $ENV_FILE ]]; then
  render_env=$ENV_EXAMPLE # --dry-run on a fresh host: render the defaults
elif [[ $QL_ENV_CREATED == 1 ]]; then
  ql_info "review $ENV_FILE (the four HOST_*_DIR values and NEXTCLOUD_TRUSTED_DOMAINS), then run $0 again"
  exit 0
fi
ql_env_load "$render_env"
app_validate_env
html_dir=$(app_dir HOST_HTML_DIR)

# ---- 3. legacy guards (Quadlet's `podman run --replace` would delete a same-named container)
for u in "${LEGACY_UNITS[@]}"; do
  if systemctl --user is-active --quiet "$u" 2>/dev/null; then
    ql_die "legacy unit $u is running; migrate this host with scripts/migrate-legacy.sh"
  fi
done
mapfile -t containers < <(app_containers)
for c in "${containers[@]}"; do ql_check_container_collision "${c%%:*}" "${c#*:}"; done
# The legacy deployment also had a cron container; it must not keep running cron.php.
if podman container exists nextcloud-cron && [[ $(podman inspect --format '{{.State.Running}}' nextcloud-cron) == true ]]; then
  ql_die "the legacy container nextcloud-cron is still running; the systemd timer replaces it (use scripts/migrate-legacy.sh)"
fi
for k in "${DATA_DIR_KEYS[@]}"; do ql_check_path_mounted "$(app_dir "$k")" "${containers[@]%%:*}"; done

# ---- 4. stage, render, validate -----------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
app_render "$WORK" "$render_env"
for f in "$WORK/out"/*; do
  u=$(ql_unit_for "$f")
  [[ -z $u ]] || ql_check_unit_shadow "$u" "$APP"
done

# Fresh install or an adopted one? (config/config.php belongs to a container subuid.)
fresh=0
if [[ $dry != 1 ]] && ! podman unshare test -f "$html_dir/config/config.php"; then fresh=1; fi

# ---- 5. data directories, images and secrets before any unit changes -----------------------
if [[ $dry != 1 ]]; then
  for k in "${DATA_DIR_KEYS[@]}"; do app_ensure_dir "$(app_dir "$k")"; done
fi
ql_pull_images "$WORK/out"
if [[ -n $db_pw_file ]]; then
  [[ -r $db_pw_file ]] || ql_die "cannot read $db_pw_file"
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:DB_PASSWORD_FROM_FILE
  DB_PASSWORD_FROM_FILE=$(<"$db_pw_file")
  ql_secret_ensure "$SECRET_DB" env:DB_PASSWORD_FROM_FILE
  unset DB_PASSWORD_FROM_FILE
else
  ql_secret_ensure "$SECRET_DB" random:32
fi
if [[ -n $admin_pw_file ]]; then
  [[ -r $admin_pw_file ]] || ql_die "cannot read $admin_pw_file"
  # shellcheck disable=SC2034 # read by ql_secret_ensure through env:ADMIN_PASSWORD_FROM_FILE
  ADMIN_PASSWORD_FROM_FILE=$(<"$admin_pw_file")
  ql_secret_ensure "$SECRET_ADMIN" env:ADMIN_PASSWORD_FROM_FILE
  unset ADMIN_PASSWORD_FROM_FILE
else
  ql_secret_ensure "$SECRET_ADMIN" random:24
fi

# ---- 6. install changed files, then start / restart only what changed ---------------------
changed=$(ql_install_files "$WORK/out" "$APP")
[[ -z $changed ]] || ql_info "changed: $(tr '\n' ' ' <<<"$changed")"
[[ $render_env != "$ENV_FILE" ]] || app_env_mark_if_changed
if [[ $dry == 1 ]]; then
  ql_info "dry-run complete; nothing was changed"
  exit 0
fi
mapfile -t units < <(app_units)
if ((no_start)); then
  systemctl --user daemon-reload
  ql_info "installed; not started (--no-start). Start with: systemctl --user start $TARGET"
  exit 0
fi
ql_apply_units "$APP" "${units[@]}"
app_env_record

# ---- 7. first install: background jobs, pgvector, indices ----------------------------------
if ((fresh)); then
  ql_info "first install: waiting for Nextcloud to finish its setup (up to ${smoke_timeout}s)"
  app_wait_status "$smoke_timeout" || ql_die "Nextcloud did not finish its setup; see: journalctl --user -u nextcloud-app.service -n 100"
  ql_info "admin user: $(ql_env_get NEXTCLOUD_ADMIN_USER admin), password: podman secret inspect --showsecret $SECRET_ADMIN"
  app_occ background:cron >/dev/null || ql_warn "occ background:cron failed"
  podman exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c 'CREATE EXTENSION IF NOT EXISTS vector' \
    || ql_warn "could not create the pgvector extension (the Recognize app needs it)"
  app_occ db:add-missing-indices >/dev/null || ql_warn "occ db:add-missing-indices failed"
fi

# ---- 8. smoke ------------------------------------------------------------------------------
if ((no_smoke)); then
  ql_info "$APP is installed and started (smoke test skipped)"
  exit 0
fi
"$REPO/tests/smoke.sh" --timeout "$smoke_timeout" || ql_die "smoke test failed; see: journalctl --user -u nextcloud-app.service -n 100"
ql_info "$APP is installed and healthy at $(app_base_url)/"
