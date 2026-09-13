# shellcheck shell=bash
# shellcheck disable=SC2034 # these settings are read by the scripts that source this file
# scripts/app.sh: Nextcloud settings and helpers shared by scripts/*.sh and tests/smoke.sh.
# Sourced after scripts/lib/quadlet-lib.sh (the vendored lib, never edited here).
# The caller sets REPO to the repository root before sourcing this file.

# ---- names -----------------------------------------------------------------------------
APP=nextcloud
export QL_APP=$APP
ENV_FILE=$HOME/.config/$APP/$APP.env
ENV_EXAMPLE=$REPO/config/$APP.env.example
PODMAN_MIN=4.9.3
TARGET=nextcloud.target
# Hand-written units of the manual deployment; they must not run next to the Quadlet units.
LEGACY_UNITS=(podman-nextcloud.service)
BACKUP_ROOT=$HOME/backups/$APP
APP_STATE_DIR=${QL_STATE_ROOT:-$HOME/.local/state/woow-quadlet}/$APP
QDIR=${QL_QUADLET_DIR:-$HOME/.config/containers/systemd}
APP_CONTAINER=nextcloud-app
DB_CONTAINER=nextcloud-db
REDIS_CONTAINER=nextcloud-redis
DB_USER=nextcloud
DB_NAME=nextcloud
SECRET_DB=nextcloud-db-password
SECRET_ADMIN=nextcloud-admin-password
DATA_DIR_KEYS=(HOST_HTML_DIR HOST_DATA_DIR HOST_POSTGRES_DIR HOST_REDIS_DIR)
# Units whose container reads ~/.config/nextcloud/nextcloud.env.
ENV_READERS=(nextcloud-app.service)

# ---- pins (the repo is the source of truth for every version) ---------------------------
app_pin() { sed -n 's/^Image=//p' "$REPO/quadlet/$1" | tail -n1; }
app_tag() {
  local last=${1##*/}
  last=${last%%@*}
  [[ $last == *:* ]] && printf '%s' "${last##*:}"
  return 0
}
# app_installed_image <unit file>: the Image= systemd runs (falls back to the repo pin when
# the unit is not installed). Smoke tests compare against this, so a rolled-back stack passes.
app_installed_image() {
  local f=$QDIR/${1##*/} i=''
  [[ -f $f ]] && i=$(sed -n 's/^Image=//p' "$f" | tail -n1)
  if [[ -n $i ]]; then printf '%s' "$i"; else app_pin "$1"; fi
}
APP_IMAGE=$(app_pin nextcloud-app.container)
DB_IMAGE=$(app_pin nextcloud-db.container)
REDIS_IMAGE=$(app_pin nextcloud-redis.container)

# ---- per-host settings --------------------------------------------------------------------
app_units() {
  printf '%s\n' "$TARGET" nextcloud-db.service nextcloud-redis.service nextcloud-app.service \
    nextcloud-cron.timer nextcloud-cron.service
}
app_containers() {
  printf '%s\n' "$DB_CONTAINER:nextcloud-db.service" "$REDIS_CONTAINER:nextcloud-redis.service" \
    "$APP_CONTAINER:nextcloud-app.service"
}

# app_spec_path <abs path>: rewrite $HOME/... as %h/... so a rendered unit carries no
# literal home path (systemd expands %h when it starts the unit)
app_spec_path() {
  local p=$1
  [[ $p == "$HOME"/* ]] && p="%h/${p#"$HOME"/}"
  printf '%s' "$p"
}

# app_dir <KEY>: the value of a HOST_*_DIR key with %h expanded
app_dir() { ql_expand_home "$(ql_env_get "$1")"; }

# app_ensure_dir <path>: create it 0700 when missing. Never chmod an existing directory:
# the html, data and database directories belong to container subuids once they are in use.
app_ensure_dir() {
  [[ -d $1 ]] && return 0
  (umask 077 && mkdir -p -- "$1") || ql_die "cannot create $1"
  ql_info "created $1"
}

# app_validate_env: dies on a value the units or Nextcloud cannot work with
app_validate_env() {
  local port k d fs html
  ql_assert_match HOST_BIND "$(ql_env_get HOST_BIND)" '[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:.]+\]'
  port=$(ql_env_get HOST_PORT)
  ql_assert_match HOST_PORT "$port" '[0-9]{1,5}'
  ((10#$port >= 1 && 10#$port <= 65535)) || ql_die "HOST_PORT=$port is not a TCP port"
  for k in "${DATA_DIR_KEYS[@]}"; do
    d=$(ql_env_get "$k")
    [[ $d == /* || $d == '%h/'* ]] || ql_die "$k=$d must be an absolute path or start with %h/ (your home directory)"
    [[ $d != *:* ]] || ql_die "$k=$d must not contain ':'"
  done
  d=$(app_dir HOST_POSTGRES_DIR)
  if [[ -d $d ]]; then
    fs=$(stat -f -c %T -- "$d" 2>/dev/null || echo unknown)
    case $fs in
      nfs* | smb* | cifs | fuseblk | 9p | tmpfs)
        ql_die "HOST_POSTGRES_DIR is on a $fs filesystem; a PostgreSQL cluster must live on local disk" ;;
    esac
  fi
  html=$(app_dir HOST_HTML_DIR)
  d=$(app_dir HOST_DATA_DIR)
  [[ $d != "$html"/* ]] || ql_warn "HOST_DATA_DIR is inside HOST_HTML_DIR; a backup of the html directory then contains every user file"
  # Nextcloud reads NC_<key> as a config.php override: a stray key here silently reconfigures it.
  for k in "${QL_ENV_KEYS[@]}"; do
    [[ $k != NC_* ]] || ql_die "$k in $ENV_FILE: keys starting with NC_ override config.php; remove it (the units set NC_dbhost)"
  done
  for k in POSTGRES_HOST POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD NEXTCLOUD_ADMIN_PASSWORD REDIS_HOST; do
    [[ -z ${QL_ENV[$k]+x} ]] || ql_warn "$k in $ENV_FILE is ignored: nextcloud-app.container sets it (passwords are podman secrets)"
  done
  return 0
}

# app_base_url: where this host reaches the published port
app_base_url() {
  local b
  b=$(ql_env_get HOST_BIND)
  case $b in 0.0.0.0) b=127.0.0.1 ;; '[::]') b='[::1]' ;; esac
  printf 'http://%s:%s' "$b" "$(ql_env_get HOST_PORT)"
}

# ---- render ---------------------------------------------------------------------------------
app_render() {
  local w=$1 env=$2
  mkdir -p "$w/src" "$w/out"
  cp -p "$REPO"/quadlet/*.container "$REPO"/quadlet/*.network "$REPO"/systemd/* "$w/src/"
  ql_render "$w/src" "$env" "$REPO/quadlet/render-vars" "$w/out"
  ql_dryrun "$w/out" --verify --ref-dir "$QDIR" || ql_die "the rendered units failed the dry-run; nothing was installed"
}

# ---- install state ----------------------------------------------------------------------------
app_manifest() { printf '%s/manifest' "$APP_STATE_DIR"; }
app_is_installed() { [[ -s $(app_manifest) ]]; }
app_require_installed() { app_is_installed || ql_die "$APP is not installed on this host (run scripts/install.sh first)"; }
app_snapshot_units() {
  local dest=$1 sha path
  mkdir -p "$dest"
  while read -r sha path; do
    [[ -n $sha && -f $path ]] || continue
    cp -p -- "$path" "$dest/"
  done <"$(app_manifest)"
}
app_env_hash() { sha256sum <"$ENV_FILE" | cut -d' ' -f1; }
app_env_mark_if_changed() {
  local f=$APP_STATE_DIR/env.sha256
  if [[ ! -f $f || $(<"$f") != "$(app_env_hash)" ]]; then ql_mark_changed "$APP" "${ENV_READERS[@]}"; fi
}
app_env_record() {
  [[ ${QL_DRY_RUN:-0} == 1 ]] && return 0
  mkdir -p "$APP_STATE_DIR" && app_env_hash >"$APP_STATE_DIR/env.sha256"
}

# ---- Nextcloud itself ---------------------------------------------------------------------------
# app_occ <args...>: occ refuses to run as root, so always as www-data
app_occ() { podman exec -u www-data "$APP_CONTAINER" php /var/www/html/occ "$@"; }

# app_status: the JSON of status.php ("" when the app does not answer)
app_status() { curl -fsS -m 10 "$(app_base_url)/status.php" 2>/dev/null || true; }
# app_status_field <json> <key>: a string or boolean field of status.php
app_status_field() {
  sed -n "s/.*\"$2\":\"\{0,1\}\([^,\"}]*\)\"\{0,1\}.*/\1/p" <<<"$1"
}
# app_installed_version: the version of the code in the html directory (x.y.z), "" when down
app_installed_version() {
  local v
  v=$(podman exec "$APP_CONTAINER" php -r 'require "/var/www/html/version.php"; echo implode(".", $OC_Version);' 2>/dev/null) || return 0
  printf '%s' "$(cut -d. -f1-3 <<<"$v")"
}
# app_image_version <image>: the NEXTCLOUD_VERSION the image ships (the upgrade target)
app_image_version() {
  podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
    | sed -n 's/^NEXTCLOUD_VERSION=//p' | tail -n1
}
app_pg_major_running() { podman exec "$DB_CONTAINER" sh -c 'echo "$PG_MAJOR"' 2>/dev/null || true; }
app_pg_major_image() {
  podman image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n 's/^PG_MAJOR=//p' | tail -n1
}
# app_maintenance on|off: fails loudly. The old scripts hid this behind `|| true`, which is
# how backups ended up being taken without maintenance mode.
app_maintenance() {
  app_occ maintenance:mode "--$1" >/dev/null || ql_die "occ maintenance:mode --$1 failed"
  ql_info "maintenance mode $1"
}
# app_wait_status <timeout> [version]: wait until status.php answers, the instance is
# installed, no database upgrade is pending and (optionally) the version matches
app_wait_status() {
  local timeout=$1 want=${2:-} json v
  local deadline=$((SECONDS + timeout))
  while :; do
    json=$(app_status)
    if [[ -n $json && $(app_status_field "$json" installed) == true && $(app_status_field "$json" needsDbUpgrade) != true ]]; then
      v=$(app_status_field "$json" versionstring)
      if [[ -z $want || $v == "$want" ]]; then
        ql_info "status.php: version $v, maintenance $(app_status_field "$json" maintenance)"
        return 0
      fi
    fi
    if ((SECONDS >= deadline)); then
      ql_warn "status.php did not report${want:+ version $want and} a finished upgrade within ${timeout}s (last: ${json:-no answer})"
      return 1
    fi
    sleep "${QL_POLL_INTERVAL:-5}"
  done
}

# ---- secrets, database ----------------------------------------------------------------------
app_save_secret() {
  local v
  v=$(podman secret inspect --showsecret --format '{{.SecretData}}' "$1") || ql_die "cannot read secret $1"
  (umask 077 && printf '%s' "$v" >"$2") || ql_die "cannot write $2"
}
app_dump_db() {
  (umask 077 && podman exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc >"$1.partial") \
    || { rm -f -- "$1.partial"; ql_die "pg_dump of $DB_NAME failed"; }
  mv -f -- "$1.partial" "$1"
  ql_info "dumped database $DB_NAME -> $1 ($(du -h -- "$1" | cut -f1))"
}
# app_dump_roles <file>: pg_dump does not carry roles, but config.php authenticates as
# oc_admin, so the role and its password hash have to be in the backup too.
app_dump_roles() {
  (umask 077 && podman exec "$DB_CONTAINER" pg_dumpall -U "$DB_USER" --roles-only >"$1.partial") \
    || { rm -f -- "$1.partial"; ql_die "pg_dumpall --roles-only failed"; }
  mv -f -- "$1.partial" "$1"
}
app_restore_db() {
  podman exec -i "$DB_CONTAINER" pg_restore -U "$DB_USER" -d postgres --clean --if-exists --create <"$1" \
    || ql_die "pg_restore of $1 failed"
  ql_info "restored database $DB_NAME from $1"
}
app_restore_roles() {
  podman exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -q >/dev/null 2>&1 <"$1" || true
}

# app_write_checksums <dir>
app_write_checksums() {
  local list
  list=$(cd -- "$1" && find . -type f ! -name 'SHA256SUMS*' ! -name '*.sha256' -printf '%P\n' | LC_ALL=C sort) \
    || ql_die "cannot list $1"
  (cd -- "$1" && umask 077 && while IFS= read -r f; do if [[ -n $f ]]; then sha256sum -- "$f"; fi; done <<<"$list" >SHA256SUMS.tmp \
    && mv -f SHA256SUMS.tmp SHA256SUMS) || ql_die "cannot write $1/SHA256SUMS"
}

# app_new_backup_dir [dir]: a fresh private directory. Without an argument it is
# ~/backups/nextcloud/<timestamp>, with -2, -3, ... when several land in the same second.
app_new_backup_dir() {
  local d=${1:-} base i=2
  if [[ -z $d ]]; then
    base=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
    d=$base
    while [[ -e $d ]]; do d=$base-$i; i=$((i + 1)); done
  fi
  [[ ! -e $d ]] || ql_die "$d already exists"
  (umask 077 && mkdir -p -- "$d") || ql_die "cannot create $d"
  printf '%s' "$d"
}

app_running() { [[ $(podman inspect --format '{{.State.Running}}' "$1" 2>/dev/null) == true ]]; }

# app_replace_dir <dir> <tgz> <suffix>: move <dir> aside as <dir>.<suffix> and put the tree
# from <tgz> back in its place.
#
# The archive's own top-level directory is extracted next to <dir> and then renamed, rather
# than unpacked into a freshly created directory: the directory ITSELF has an owner and a
# mode that matter. /var/www/html and its config directory belong to the container's
# www-data, and a directory created here belongs to the host user - root inside the
# container - so Apache could not read it. The entrypoint only repairs that on a version
# bump, which is exactly what a rollback to the same version is not.
app_replace_dir() {
  local dir=$1 tgz=$2 sfx=$3 parent top
  [[ -f $tgz ]] || ql_die "$tgz is missing"
  dir=${dir%/}
  parent=${dir%/*}
  [[ -n $parent ]] || parent=/
  # The archive's top-level name is the source host's name for the directory, which need
  # not be its name here.
  top=$({ podman unshare tar -tzf "$tgz" || true; } | sed -n '1s#^\./##;1s#/.*##;1p')
  [[ -n $top && $top != . && $top != .. && $top != */* ]] || ql_die "cannot read the top-level directory of $tgz"
  if [[ $parent/$top != "$dir" ]] && podman unshare test -e "$parent/$top"; then
    ql_die "$parent/$top is in the way of restoring ${tgz##*/}; move it away first"
  fi
  if podman unshare test -d "$dir"; then
    podman unshare mv -- "$dir" "$dir.$sfx" || ql_die "cannot move $dir aside"
    ql_info "kept the previous $dir as $dir.$sfx"
  fi
  podman unshare tar --numeric-owner -xzf "$tgz" -C "$parent" || ql_die "cannot extract $tgz into $parent"
  if [[ $parent/$top != "$dir" ]]; then
    podman unshare mv -- "$parent/$top" "$dir" || ql_die "cannot move $parent/$top to $dir"
  fi
  ql_info "restored $dir from ${tgz##*/}"
}

app_confirm() {
  [[ ${ASSUME_YES:-0} == 1 || ${QL_DRY_RUN:-0} == 1 ]] && return 0
  [[ -t 0 ]] || ql_die "$1; add --yes to confirm non-interactively"
  local answer
  read -r -p "$1. Type '$APP' to continue: " answer
  [[ $answer == "$APP" ]] || ql_die "aborted; nothing was changed"
}

# ---- the legacy rollback model (STANDARD 7a; quadlet-lib >= 1.4.0) -----------------------
# Keeping the legacy containers renamed and stopped is a rollback path only while nothing
# starts them again. The user unit podman-restart.service runs
# `podman start --all --filter restart-policy=always` at boot, so where it is enabled a
# renamed, stopped container whose policy is exactly `always` revives and fights the new
# Quadlet container for its name, ports and volumes. podman 4.9.3 cannot defuse that in
# place - `podman update` is cgroup-only, a restart policy is fixed at create time - so the
# answer there is to capture the container and remove it. ql_rollback_strategy asks this
# host (is that unit enabled, what is each container's policy) and answers `rename` or
# `capture`; it never looks at a host name.

# app_legacy_capture <backup dir> <container>...: write the rollback copy of each container.
# Read-only towards the containers, so it belongs in the prepare phase, before any downtime:
# a container the library cannot replay (an empty CreateCommand - created through the podman
# API rather than the CLI) is refused here, while the legacy stack is still running.
app_legacy_capture() {
  local bk=${1:?usage: app_legacy_capture <backup dir> <container>...} c meta
  shift
  for c in "$@"; do
    meta=$bk/legacy-container/$c/meta
    if [[ -f $meta ]]; then
      ql_info "the rollback copy of $c is already in $bk/legacy-container/$c"
    else
      ql_capture_container "$c" "$bk" >/dev/null
    fi
    [[ $(sed -n 's/^RECREATABLE=//p' "$meta" | tail -n1) == 1 ]] || ql_die \
      "$c was created through the podman API, not the CLI, so its create command cannot be replayed and a capture-based rollback is impossible. Either disable podman-restart.service (then the legacy containers can simply be renamed) or plan to rebuild $c by hand from $bk/legacy-container/$c/inspect.json"
  done
}

# app_legacy_retire <strategy> <suffix> <backup dir> <container>...: take the legacy
# containers out of the new stack's way, in the shape the strategy asked for.
app_legacy_retire() {
  # The suffix is empty on the capture path: nothing is renamed there, so there is no
  # <name>-legacy-<suffix> to name. ${2-} rather than ${2:?}, which would abort the script.
  local strategy=${1:?} sfx=${2-} bk=${3:?} c
  shift 3
  for c in "$@"; do
    case $strategy in
      rename)
        [[ -n $sfx ]] || ql_die "the rename path needs a suffix for $c-legacy-<suffix>"
        podman rename "$c" "$c-legacy-$sfx" || ql_die "podman rename $c failed"
        ql_info "renamed $c -> $c-legacy-$sfx (stopped, kept for --rollback)" ;;
      capture)
        [[ -f $bk/legacy-container/$c/meta ]] || ql_die "no rollback copy of $c in $bk; nothing was removed"
        # A plain rm on purpose: `podman rm -v` would delete the anonymous volumes that the
        # capture records and expects to find again.
        podman rm "$c" >/dev/null || ql_die "podman rm $c failed"
        ql_info "removed $c; --rollback recreates it from $bk/legacy-container/$c" ;;
      *) ql_die "unknown rollback strategy '$strategy'" ;;
    esac
  done
}

# app_legacy_restore <suffix> <backup dir> <container>...: bring the legacy containers back,
# whichever shape the cutover used. A recreated container comes back stopped and with its
# original restart policy; the caller starts it, exactly as it starts a renamed one.
app_legacy_restore() {
  # An empty suffix means the cutover captured rather than renamed: there is no
  # <name>-legacy-<suffix> to look for, only the rollback copy.
  local sfx=${1-} bk=${2:?} c
  shift 2
  for c in "$@"; do
    if [[ -n $sfx ]] && podman container exists "$c-legacy-$sfx"; then
      podman rename "$c-legacy-$sfx" "$c" || ql_die "podman rename $c-legacy-$sfx failed"
      ql_info "renamed $c-legacy-$sfx -> $c"
    elif [[ -f $bk/legacy-container/$c/meta ]]; then
      ql_recreate_container "$bk" "$c" >/dev/null || ql_die "could not recreate $c from $bk"
      ql_info "recreated $c from $bk/legacy-container/$c (stopped, with its original restart policy)"
    else
      ql_die "neither the renamed container ${sfx:+$c-legacy-$sfx }nor a rollback copy in $bk exists; restore $c by hand"
    fi
  done
}
