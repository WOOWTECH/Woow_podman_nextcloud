# shellcheck shell=bash
# shellcheck disable=SC2154,SC2034 # REPO and failures belong to tests/dryrun.sh
# tests/dryrun.local.sh: Nextcloud-specific checks, sourced at the end of tests/dryrun.sh.
#   1. The app image must be pinned to an -apache tag of an exact version: `stable` moves
#      (it was 34.0.3 on 2026-09-12 and will become 34.0.4), and the entrypoint refuses to
#      start on data written by a newer release.
#   2. The cron service must run cron.php as www-data: occ and cron.php refuse to run as
#      root, and the old scripts hid that behind `|| true`.

img=$(sed -n 's#^Image=##p' "$REPO/quadlet/nextcloud-app.container")
if [[ $img =~ ^docker\.io/library/nextcloud:[0-9]+\.[0-9]+\.[0-9]+-apache$ ]]; then
  echo "ok   app image pinned to an exact version: $img"
else
  echo "FAIL app image '$img' is not docker.io/library/nextcloud:<x.y.z>-apache"
  failures=$((failures + 1))
fi

if grep -q '^ExecStart=/usr/bin/podman exec -u www-data nextcloud-app php -f /var/www/html/cron.php$' \
  "$REPO/systemd/nextcloud-cron.service"; then
  echo "ok   cron.php runs as www-data"
else
  echo "FAIL systemd/nextcloud-cron.service must run cron.php as www-data"
  failures=$((failures + 1))
fi
