#!/usr/bin/env bash
# tests/version-check.sh: pins app_image_version and app_pg_major_image (scripts/app.sh), the
# pre-flight image-version readers scripts/migrate-legacy.sh calls before a cutover.
#
# Confirmed live on woowtechopenclaw: the checkout's pinned Nextcloud image tag was not yet
# cached locally (a fresh migration host, or one that had only ever pulled an older tag).
# `podman image inspect` on an uncached image fails (podman 4.9.3: exit 125), and under this
# script's `set -euo pipefail` that failure survived through the `| sed -n ... | tail -n1`
# pipeline even though sed and tail both exit 0 on empty input: bash's pipefail reports the
# exit status of the last command IN THE PIPELINE to fail, not the last command to run, so
# `tgt=$(app_image_version "$APP_IMAGE")` died right there - before migrate-legacy.sh's own
# "empty? pull it, then read again" fallback a few lines below ever ran. The fix reads
# podman's output into a local variable first (with its own `|| out=''`), so the function
# always returns 0 with an empty string instead of propagating podman's exit code.
#
# podman is the double in tests/shims (SHIM_STATE/image-ids/<key> "cached", absent "not
# cached, podman image inspect fails" - see tests/shims/podman's `image inspect`).
#
#   tests/version-check.sh [name-filter]
# shellcheck disable=SC2030,SC2031
# shellcheck source-path=SCRIPTDIR
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
SHIMS=$HERE/shims
FILTER=${1:-}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nextcloud-version-check-tests.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
npass=0 nfail=0
FAILED=()

die_t() { printf 'ASSERTION FAILED: %s\n' "$*" >&2; exit 1; }
eq() { [[ $1 == "$2" ]] || die_t "${3:-value}: expected [$2] got [$1]"; }
has() { [[ $1 == *"$2"* ]] || die_t "${3:-output} lacks [$2] in:"$'\n'"$1"; }
OUT=''
expect_ok() { OUT=$( ("$@") 2>&1) || die_t "expected success of: $*"$'\n'"$OUT"; }
expect_fail() { if OUT=$( ("$@") 2>&1); then die_t "expected failure of: $*"$'\n'"$OUT"; fi; }

imgkey() { printf '%s' "${1//[\/:@]/_}"; }
# cache_image <ref> <NEXTCLOUD_VERSION> [PG_MAJOR]: the image is already pulled, with this
# env baked into its config - real podman's `podman image inspect --format
# '{{range .Config.Env}}{{println .}}{{end}}'`.
cache_image() {
  # nc/pg are documentation of intent for the test that calls this (which version is meant
  # to be "cached"); tests/shims/podman's `image inspect` only ever echoes the image id back
  # (it does not model .Config.Env), so nothing here actually consumes them.
  local ref=$1
  mkdir -p "$SHIM_STATE/image-ids"
  printf 'imgid-%s' "${ref##*:}" >"$SHIM_STATE/image-ids/$(imgkey "$ref")"
}
# not_cached: nothing to do - the absence of an image-ids entry IS "not cached locally"
# (tests/shims/podman's `image inspect` then fails, exit 125, exactly as real podman does).

# ---- the openclaw shape: exact tag not cached locally, image_version must not die ---------
# Before the fix, `tgt=$(app_image_version "$APP_IMAGE")` under `set -euo pipefail` died here
# and migrate-legacy.sh's own pull-then-retry fallback never ran.
t_uncached_image_version_returns_empty_not_a_pipefail_death() {
  local out rc=0
  out=$(app_image_version "$APP_IMAGE" 2>&1) || rc=$?
  eq "$rc" 0 "app_image_version must return 0 even when the image is not cached"
  eq "$out" "" "an uncached image has no version to report"
}
t_uncached_pg_major_image_returns_empty_not_a_pipefail_death() {
  local out rc=0
  out=$(app_pg_major_image "$DB_IMAGE" 2>&1) || rc=$?
  eq "$rc" 0 "app_pg_major_image must return 0 even when the image is not cached"
  eq "$out" "" "an uncached image has no PG_MAJOR to report"
}
# The exact scenario migrate-legacy.sh's pre-flight relies on: read tgt (empty, uncached),
# pull, read again (now cached) - all three steps must run without the script dying partway.
t_the_pull_then_reread_fallback_now_runs_to_completion() {
  local tgt
  tgt=$(app_image_version "$APP_IMAGE")
  eq "$tgt" "" "uncached: empty, as migrate-legacy.sh's own \`[[ -z \$tgt ]]\` expects"
  podman pull "$APP_IMAGE" >/dev/null
  cache_image "$APP_IMAGE" 34.0.3
  tgt=$(app_image_version "$APP_IMAGE")
  eq "$tgt" "" "the shim's cache_image does not fabricate a Config.Env NEXTCLOUD_VERSION; presence of an image id is what matters"
}

# ---- a cached image still reports its real version, and a genuine mismatch is unaffected --
# (the pipefail fix must not touch the actual parsing of a successful `podman image inspect`)
t_cached_image_version_is_read_normally() {
  mkdir -p "$SHIM_STATE/image-ids"
  printf 'imgid-x' >"$SHIM_STATE/image-ids/$(imgkey "$APP_IMAGE")"
  # tests/shims/podman's `image inspect` only ever prints the cached image id (it does not
  # model .Config.Env), so this pins the "cached -> succeeds" half of the contract; the
  # NEXTCLOUD_VERSION parsing itself is real sed/tail, exercised end to end on a real host.
  local rc=0
  app_image_version "$APP_IMAGE" >/dev/null 2>&1 || rc=$?
  eq "$rc" 0 "a cached image must not fail either"
}

# ---- the safety net itself: a genuine version mismatch must still refuse ------------------
# The pipefail fix only changes how app_image_version/app_pg_major_image behave when the
# image is not cached; it must not weaken migrate-legacy.sh's actual "migrate at the same
# version, then upgrade" comparison. Pinned as a structural check (not a full pre-flight
# run, which would need curl/occ/mount-inspection shims well beyond this bug) so a future
# edit cannot silently relax `$cur == "$tgt"` into a substring or `|| true` bypass.
t_the_same_version_comparison_is_still_an_exact_equality_that_dies() {
  grep -qE "\\[\\[ -n \\\$cur && \\\$cur == \"\\\$tgt\" \\]\\]" "$REPO/scripts/migrate-legacy.sh" \
    || die_t "migrate-legacy.sh no longer does an exact cur==tgt comparison"
  grep -q "the legacy Nextcloud runs.*but this checkout pins" "$REPO/scripts/migrate-legacy.sh" \
    || die_t "the version-mismatch ql_die message is gone"
  # the comparison line itself must still end in ql_die, not a tolerated `|| true`/`|| :`
  local line
  line=$(grep -A1 -E "\\[\\[ -n \\\$cur && \\\$cur == \"\\\$tgt\" \\]\\]" "$REPO/scripts/migrate-legacy.sh")
  has "$line" 'ql_die' "a version mismatch must still be fatal"
}
t_app_image_version_still_parses_the_real_pinned_key() {
  grep -q "s/^NEXTCLOUD_VERSION=//p" "$REPO/scripts/app.sh" \
    || die_t "app_image_version no longer parses NEXTCLOUD_VERSION"
}

run() {
  local t=$1 log rc
  [[ -z $FILTER || $t == *"$FILTER"* ]] || return 0
  log=$ROOT/$t.log
  (
    set -euo pipefail
    T=$ROOT/$t
    mkdir -p "$T/home" "$T/state" "$T/run"
    export HOME=$T/home SHIM_STATE=$T/state XDG_RUNTIME_DIR=$T/run USER=tester TMPDIR=$T
    export PATH="$SHIMS:$PATH" QL_LOG_PREFIX=version-check
    unset QL_DRY_RUN QL_STATE_ROOT QL_QUADLET_DIR QL_CONFIG_ROOT
    [[ $(command -v podman) == "$SHIMS/podman" ]] || die_t "the podman shim is not first on PATH; refusing to run"
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
