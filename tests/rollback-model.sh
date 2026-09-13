#!/usr/bin/env bash
# tests/rollback-model.sh: pins the rollback model that scripts/migrate-legacy.sh uses to keep
# the legacy containers available (STANDARD 7a). The three helpers it exercises -
# app_legacy_capture, app_legacy_retire and app_legacy_restore, defined in scripts/app.sh -
# are the only code that decides between "rename and leave stopped" and "capture and remove",
# so pinning them pins the cutover and the rollback.
#
#   tests/rollback-model.sh [name-filter]
#
# podman and systemctl are the doubles in tests/shims, placed first on PATH; every test gets
# its own HOME and shim state. No container is created and the real user manager is never
# touched. Two host shapes are modelled:
#   toypark1234      podman-restart.service disabled -> rename, exactly as the seven live
#                    migrations behave today
#   woowtechopenclaw podman-restart.service enabled and a container with restart-policy
#                    `always` -> capture and remove, because a renamed copy would revive at
#                    the next boot and fight the new Quadlet container
#
# Every test runs in its own subshell on purpose (isolated HOME, shim state, env), so the
# "modified in a subshell" notes do not apply here:
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nextcloud-rollback-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
hasnt() { [[ $1 != *"$2"* ]] || die_t "${3:-output} must not contain [$2] in:"$'\n'"$1"; }
calls() { cat "$SHIM_STATE/calls"; }
ncalls() { grep -cF -- "$1" "$SHIM_STATE/calls" || true; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

# ---- fixtures ---------------------------------------------------------------------------
# mk_legacy <name> <policy>: a podman-compose style legacy container in the shim state. Its
# CreateCommand is a `podman run` that carries -d/--rm/--replace/--cidfile and NO --restart,
# which is how podman-compose leaves one (the policy lives on the container object only).
mk_legacy() {
  local name=$1 policy=$2 image=docker.io/library/nextcloud:stable d
  d=$SHIM_STATE/containers/$name
  mkdir -p "$d" "$SHIM_STATE/image-ids"
  printf '%s' "$policy" >"$d/policy"
  printf '0' >"$d/retries"
  printf 'cid-%s' "$name" >"$d/id"
  printf '%s' "$image" >"$d/image"
  printf 'imgid-nextcloud' >"$d/image_id"
  printf 'imgid-nextcloud' >"$SHIM_STATE/image-ids/${image//[\/:@]/_}"
  printf 'bridge' >"$d/netmode"
  printf 'false' >"$d/autoremove"
  printf 'nextcloud' >"$d/project"
  printf '%s' "$name" >"$d/service"
  printf '4096' >"$d/sizerw"
  printf 'bind||/srv/nextcloud/html|/var/www/html|true|rprivate\n' >"$d/mounts"
  printf 'nextcloud-network|%s cid-%s |10.89.1.7|aa:bb:cc:dd:ee:02\n' "$name" "$name" >"$d/networks"
  printf '80/tcp|127.0.0.1:18080 \n' >"$d/ports"
  printf 'io.podman.compose.project=nextcloud\n' >"$d/labels"
  : >"$d/label"
  printf '%s\0' /usr/bin/podman run "--name=$name" -d --rm --replace \
    --cidfile "/run/user/1000/$name.cid" --label io.podman.compose.project=nextcloud \
    -v /srv/nextcloud/html:/var/www/html --net nextcloud-network -e PHP_MEMORY_LIMIT=1G \
    docker.io/library/nextcloud:stable >"$d/createcommand.argv0"
}
# mk_api_created <name> <policy>: a container created through the podman API (docker-compose
# over the socket, podman play): its CreateCommand is empty, so nothing can be replayed.
mk_api_created() {
  mk_legacy "$1" "$2"
  : >"$SHIM_STATE/containers/$1/createcommand.argv0"
}
enable_restart_unit() { # what woowtechopenclaw looks like
  mkdir -p "$SHIM_STATE/units/podman-restart.service"
  echo enabled >"$SHIM_STATE/units/podman-restart.service/UnitFileState"
}

# ---- the toypark shape: rename, and nothing else ------------------------------------------
t_disabled_restart_unit_keeps_the_rename_path() {
  mk_legacy nextcloud-db unless-stopped
  mk_legacy nextcloud-app unless-stopped
  eq "$(ql_rollback_strategy nextcloud-db nextcloud-app 2>/dev/null)" rename "strategy on a toypark-like host"
  expect_ok app_legacy_retire rename 20260914 "$T/bk" nextcloud-db nextcloud-app
  has "$OUT" "renamed nextcloud-app -> nextcloud-app-legacy-20260914"
  eq "$(ncalls 'podman rename nextcloud-db nextcloud-db-legacy-20260914')" 1 "rename of the db"
  eq "$(ncalls 'podman rename nextcloud-app nextcloud-app-legacy-20260914')" 1 "rename of nextcloud-app"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed on the rename path"
  eq "$(ncalls 'podman commit')" 0 "nothing is committed on the rename path"
  [[ ! -d $T/bk/legacy-container ]] || die_t "the rename path must not write a capture"
  podman container exists nextcloud-app-legacy-20260914 || die_t "the renamed container is missing"
  # and the rollback renames them straight back
  expect_ok app_legacy_restore 20260914 "$T/bk" nextcloud-db nextcloud-app
  has "$OUT" "renamed nextcloud-app-legacy-20260914 -> nextcloud-app"
  podman container exists nextcloud-app || die_t "the rollback did not bring nextcloud-app back"
  eq "$(ncalls 'podman create')" 0 "a renamed container is not recreated"
}

t_always_policy_with_a_disabled_unit_is_still_rename() {
  mk_legacy nextcloud-app always
  mk_legacy nextcloud-db always
  eq "$(ql_rollback_strategy nextcloud-db nextcloud-app 2>/dev/null)" rename "a disabled unit never revives anything"
}

# ---- the openclaw shape: capture, then remove ---------------------------------------------
t_enabled_restart_unit_and_always_policy_takes_the_capture_path() {
  enable_restart_unit
  mk_legacy nextcloud-db always
  mk_legacy nextcloud-app always
  eq "$(ql_rollback_strategy nextcloud-db nextcloud-app 2>/dev/null)" capture "strategy on an openclaw-like host"
  expect_ok app_legacy_capture "$T/bk" nextcloud-db nextcloud-app
  for c in nextcloud-app nextcloud-db; do
    [[ -s $T/bk/legacy-container/$c/meta ]] || die_t "no capture of $c"
    eq "$(sed -n 's/^RECREATABLE=//p' "$T/bk/legacy-container/$c/meta")" 1 "$c is recreatable"
    eq "$(sed -n 's/^RESTART_POLICY=//p' "$T/bk/legacy-container/$c/meta")" always "$c policy recorded"
  done
  # capturing is read-only: the legacy stack is still up at this point
  eq "$(ncalls 'podman rm ')" 0 "the capture removes nothing"
  eq "$(ncalls 'podman rename')" 0 "the capture renames nothing"
  expect_ok app_legacy_retire capture 20260914 "$T/bk" nextcloud-db nextcloud-app
  has "$OUT" "removed nextcloud-app;"
  eq "$(ncalls 'podman rename')" 0 "the capture path must not rename"
  podman container exists nextcloud-app && die_t "nextcloud-app was not removed"
  podman container exists nextcloud-app-legacy-20260914 && die_t "the capture path must not leave a renamed copy"
  return 0
}

t_the_capture_path_never_removes_the_anonymous_volumes() {
  enable_restart_unit
  mk_legacy nextcloud-app always
  expect_ok app_legacy_capture "$T/bk" nextcloud-app
  expect_ok app_legacy_retire capture 20260914 "$T/bk" nextcloud-app
  hasnt "$(calls)" "podman rm -v" "rm -v would delete the anonymous volumes the capture expects back"
  hasnt "$(calls)" "podman rm --volumes" "rm --volumes would delete the anonymous volumes"
}

t_the_rollback_recreates_a_captured_container_with_its_policy() {
  enable_restart_unit
  mk_legacy nextcloud-app always
  expect_ok app_legacy_capture "$T/bk" nextcloud-app
  expect_ok app_legacy_retire capture 20260914 "$T/bk" nextcloud-app
  expect_ok app_legacy_restore 20260914 "$T/bk" nextcloud-app
  has "$OUT" "recreated nextcloud-app"
  podman container exists nextcloud-app || die_t "the rollback did not recreate nextcloud-app"
  eq "$(ql_container_restart_policy nextcloud-app)" always "the original restart policy comes back"
}

t_capture_refuses_a_container_the_library_cannot_replay() {
  enable_restart_unit
  mk_api_created nextcloud-app always
  expect_fail app_legacy_capture "$T/bk" nextcloud-app
  has "$OUT" "podman API"
  eq "$(ncalls 'podman rm ')" 0 "a refused capture removes nothing"
}

t_retire_refuses_to_remove_without_a_capture() {
  enable_restart_unit
  mk_legacy nextcloud-app always
  expect_fail app_legacy_retire capture 20260914 "$T/bk" nextcloud-app
  has "$OUT" "no rollback copy of nextcloud-app"
  eq "$(ncalls 'podman rm ')" 0 "nothing is removed without a capture"
}

t_capture_is_idempotent_between_prepare_only_and_the_cutover() {
  enable_restart_unit
  mk_legacy nextcloud-app always
  expect_ok app_legacy_capture "$T/bk" nextcloud-app # --prepare-only
  expect_ok app_legacy_capture "$T/bk" nextcloud-app # the cutover reuses the same backup dir
  has "$OUT" "already in"
}

t_migrate_legacy_asks_the_host_instead_of_refusing() {
  # the blanket refusal this replaces died on `is-enabled podman-restart.service` alone
  grep -q 'ql_rollback_strategy' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "scripts/migrate-legacy.sh does not ask ql_rollback_strategy"
  grep -q 'is-enabled podman-restart.service' "$REPO/scripts/migrate-legacy.sh" \
    && die_t "scripts/migrate-legacy.sh still refuses on podman-restart.service by itself"
  grep -q 'app_legacy_retire' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "the cutover does not go through app_legacy_retire"
  grep -q 'app_legacy_restore' "$REPO/scripts/migrate-legacy.sh" \
    || die_t "the rollback does not go through app_legacy_restore"
  return 0
}

t_the_capture_path_works_with_an_empty_suffix() {
  # A capture-path cutover renames nothing, so it has no <name>-legacy-<suffix> to name and
  # passes an empty suffix. `${2:?}` would abort the script there; `${2-}` must not.
  enable_restart_unit
  mk_legacy nextcloud-app always
  expect_ok app_legacy_capture "$T/bk" nextcloud-app
  expect_ok app_legacy_retire capture "" "$T/bk" nextcloud-app
  podman container exists nextcloud-app && die_t "nextcloud-app was not removed"
  expect_ok app_legacy_restore "" "$T/bk" nextcloud-app
  has "$OUT" "recreated nextcloud-app"
  eq "$(ql_container_restart_policy nextcloud-app)" always "the original restart policy comes back"
  # and with no capture either, the refusal names only what could exist
  expect_fail app_legacy_restore "" "$T/empty" nextcloud-app
  hasnt "$OUT" "-legacy- " "an empty suffix must not be spelled into the message"
  return 0
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run" "$T/bk"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_POLL_INTERVAL=0.05 QL_LOG_PREFIX=rollback-model
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    : >"$SHIM_STATE/calls"
    [[ $(command -v podman) == "$SHIMS/podman" && $(command -v systemctl) == "$SHIMS/systemctl" ]] \
      || die_t "the shims are not first on PATH; refusing to run"
    # shellcheck source=../scripts/lib/quadlet-lib.sh
    . "$REPO/scripts/lib/quadlet-lib.sh"
    # shellcheck source=../scripts/app.sh
    . "$REPO/scripts/app.sh"
    "$t"
  ) >"$log" 2>&1
  rc=$?
  if ((rc == 0)); then
    npass=$((npass + 1))
    printf 'ok    %s\n' "$t"
  else
    nfail=$((nfail + 1))
    FAILED+=("$t")
    printf 'FAIL  %s\n' "$t"
    tail -n 25 "$log" | sed 's/^/      | /'
  fi
}

for t in $(declare -F | sed -n 's/^declare -f \(t_.*\)$/\1/p'); do run "$t"; done
printf '\n%d passed, %d failed\n' "$npass" "$nfail"
((nfail == 0)) || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
