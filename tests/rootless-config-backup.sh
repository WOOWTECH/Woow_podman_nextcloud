#!/usr/bin/env bash
# Reproduce a config directory hidden from the host owner by a container UID.
# Uses a private temporary tree and podman unshare; no images or services needed.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"
[[ $(id -u) != 0 ]] || { echo 'Run as a rootless Podman user' >&2; exit 1; }
fixture=$(mktemp -d)
trap 'podman unshare rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/html/config" "$fixture/output"
printf '%s\n' 'private-config-fixture' >"$fixture/html/config/config.php"
podman unshare chown -R 33:33 "$fixture/html"
podman unshare chmod 0700 "$fixture/html"
[[ ! -d $fixture/html/config ]] # The old host-side check incorrectly skipped it.
app_backup_config "$fixture/html" "$fixture/output/config.tgz"
[[ $(tar -xOzf "$fixture/output/config.tgz" config/config.php) == private-config-fixture ]]
[[ $(stat -c '%a' "$fixture/output/config.tgz") == 600 ]]
(cd "$fixture/output" && sha256sum -c config.tgz.sha256)
before=$(sha256sum "$fixture/output/config.tgz")
if (app_backup_config "$fixture/html" "$fixture/output/config.tgz") >/dev/null 2>&1; then
  echo 'An existing archive was overwritten' >&2; exit 1
fi
[[ $(sha256sum "$fixture/output/config.tgz") == "$before" ]]
if (app_backup_config "$fixture/missing" "$fixture/output/missing.tgz") >/dev/null 2>&1; then
  echo 'Missing configuration was accepted' >&2; exit 1
fi
[[ ! -e $fixture/output/missing.tgz ]]
echo 'Rootless configuration archive, overwrite refusal and missing-config failure passed.'
