#!/usr/bin/env bash
# tests/smoke.sh: post-install health checks for the Nextcloud stack. Exit 0 = healthy.
#
#   tests/smoke.sh [--timeout S] [--public-url URL]
#
#   --timeout S       seconds to wait for the healthchecks and status.php (default 900: the
#                     entrypoint rsyncs the release and may run occ upgrade)
#   --public-url URL  also GET <URL>/status.php through the tunnel / proxy
#
# Checks: the units and the cron timer are active, the containers are healthy, status.php
# reports installed and not in maintenance with the version of the installed unit, occ works
# (which proves the database password really authenticates), the database and Redis hosts are
# the bridge names, one cron run succeeds, and the port listens only on HOST_BIND.
# The only thing it changes is that single cron.php run.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"
export QL_LOG_PREFIX=smoke QL_HEALTH_ACTIVE=1

timeout=900 public_url=''
while (($#)); do
  case $1 in
    --timeout) timeout=${2:?--timeout needs seconds}; shift ;;
    --public-url) public_url=${2:?--public-url needs a URL}; shift ;;
    -h | --help) sed -n '2,15p' "$0"; exit 0 ;;
    *) ql_die "unknown option $1 (see --help)" ;;
  esac
  shift
done
ql_env_load "$ENV_FILE"

fails=0
ok() { ql_info "ok   $*"; }
bad() { ql_warn "FAIL $*"; fails=$((fails + 1)); }
check() {
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}

# 1. units (the cron service is oneshot: it is not "active" between runs)
for u in "$TARGET" nextcloud-db.service nextcloud-redis.service nextcloud-app.service nextcloud-cron.timer; do
  check "$u is active" systemctl --user is-active --quiet "$u"
done

# 2. podman healthchecks
mapfile -t containers < <(app_containers)
for c in "${containers[@]}"; do check "${c%%:*} is healthy" ql_wait_container_healthy "${c%%:*}" "$timeout"; done

# 3. status.php: installed, not in maintenance, the version of the installed unit
want=$(app_image_version "$(app_installed_image nextcloud-app.container)")
check "status.php reports an installed instance${want:+ at $want}" app_wait_status "$timeout" "$want"
json=$(app_status)
if [[ $(app_status_field "$json" maintenance) == false ]]; then
  ok "maintenance mode is off"
else
  bad "Nextcloud is still in maintenance mode: occ maintenance:mode --off"
fi

# 4. occ works, and the database and Redis are reached over the bridge
if app_occ status >/dev/null 2>&1; then
  ok "occ status works (the database password authenticates over the bridge)"
else
  bad "occ status failed: podman exec -u www-data $APP_CONTAINER php /var/www/html/occ status"
fi
dbhost=$(app_occ config:system:get dbhost 2>/dev/null | tr -d '\r\n' || true)
if [[ $dbhost == "$DB_CONTAINER" ]]; then ok "dbhost is $dbhost"; else bad "dbhost is '${dbhost:-?}', expected $DB_CONTAINER (NC_dbhost override)"; fi
redishost=$(app_occ config:system:get redis host 2>/dev/null | tr -d '\r\n' || true)
if [[ $redishost == "$REDIS_CONTAINER" ]]; then ok "redis host is $redishost"; else bad "redis host is '${redishost:-?}', expected $REDIS_CONTAINER"; fi
pong=$(podman exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | tr -d '\r\n' || true)
if [[ $pong == PONG ]]; then ok "redis answers PONG"; else bad "redis-cli ping returned '${pong:-nothing}'"; fi

# 5. the background jobs really run
if systemctl --user start nextcloud-cron.service 2>/dev/null; then
  result=$(systemctl --user show -p Result --value nextcloud-cron.service 2>/dev/null || true)
  if [[ $result == success ]]; then ok "a cron.php run finished (Result=success)"; else bad "nextcloud-cron.service Result=$result"; fi
else
  bad "could not start nextcloud-cron.service"
fi
mode=$(app_occ config:app:get core backgroundjobs_mode 2>/dev/null | tr -d '\r\n' || true)
if [[ $mode == cron ]]; then ok "background jobs mode is cron"; else bad "background jobs mode is '${mode:-?}', expected cron (occ background:cron)"; fi

# 6. setup checks: reported, never fatal. Several of them (HTTPS, .well-known, headers) are
# about the proxy in front of Nextcloud, not about this deployment.
if errors=$(app_occ setupchecks --output=json 2>/dev/null | tr ',' '\n' | grep -c '"severity":"error"' || true); then
  if [[ ${errors:-0} == 0 ]]; then
    ok "occ setupchecks reports no error-severity item"
  else
    ql_warn "note: occ setupchecks reports $errors error-severity item(s); review with: occ setupchecks"
  fi
fi

# 7. the published port listens only where HOST_BIND says
port=$(ql_env_get HOST_PORT) bind=$(ql_env_get HOST_BIND)
expected_listener() {
  case $1 in
    "$bind:$port") return 0 ;;
    "0.0.0.0:$port" | "*:$port") [[ $bind == 0.0.0.0 ]] ;;
    *) return 1 ;;
  esac
}
if command -v ss >/dev/null 2>&1; then
  mapfile -t listeners < <(ss -ltnH "sport = :$port" | awk '{print $4}' | sort -u)
  unexpected=0
  for l in "${listeners[@]}"; do expected_listener "$l" || unexpected=1; done
  if ((${#listeners[@]} && !unexpected)); then
    ok "port $port listens on ${listeners[*]}"
  else
    bad "port $port listeners '${listeners[*]}' do not match HOST_BIND=$bind"
  fi
else
  ql_info "note: ss not found; listener check skipped"
fi

# 8. through the tunnel / proxy
if [[ -n $public_url ]]; then
  check "GET ${public_url%/}/status.php" ql_wait_http "${public_url%/}/status.php" 200 120
fi

if ((fails)); then
  ql_warn "$fails check(s) failed"
  exit 1
fi
ql_info "all checks passed"
