#!/usr/bin/env bash
# Actual app_render/manifest snapshot behavior, in a disposable tree. No services.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$ENV_EXAMPLE" "$work/settings.env"
chmod 600 "$work/settings.env"
ql_env_load "$work/settings.env"
QDIR=$work/refs
mkdir "$QDIR"
app_render "$work/base" "$work/settings.env"
[[ ! -f $work/base/out/nextcloud-office.container ]]
sed -i 's/WOOW_OFFICE_ENABLED=0/WOOW_OFFICE_ENABLED=1/' "$work/settings.env"
ql_env_load "$work/settings.env"
app_render "$work/office" "$work/settings.env"
[[ -f $work/office/out/config/gateway.conf ]]
grep -q 'PublishPort=127.0.0.1:18080:80' "$work/office/out/nextcloud-app.container"
grep -q 'PublishPort=127.0.0.1:18081:8080' "$work/office/out/nextcloud-gateway.container"
grep -q '^WantedBy=default.target nextcloud.target' "$work/office/out/nextcloud-office.container"
app_units | grep -qx 'nextcloud-office.service'
app_units | grep -qx 'nextcloud-gateway.service'
app_containers | grep -qx 'nextcloud-office:nextcloud-office.service'
cp "$work/settings.env" "$work/invalid.env"
sed -i 's|OFFICE_ORIGIN=.*|OFFICE_ORIGIN=http://localhost/;injection|' "$work/invalid.env"
if (ql_env_load "$work/invalid.env"; app_render "$work/invalid" "$work/invalid.env") 2>/dev/null; then
  echo 'Invalid Office origin accepted' >&2; exit 1
fi
cp "$work/settings.env" "$work/invalid.env"
sed -i 's/OFFICE_PORT=18081/OFFICE_PORT=18080/' "$work/invalid.env"
if (ql_env_load "$work/invalid.env"; app_render "$work/invalid-port" "$work/invalid.env") 2>/dev/null; then
  echo 'Conflicting Office port accepted' >&2; exit 1
fi
# Snapshot layout must be acceptable to ql_install_files during rollback.
APP_STATE_DIR=$work/state
export QL_CONFIG_ROOT=$work/config-root
mkdir -p "$APP_STATE_DIR" "$QL_CONFIG_ROOT/nextcloud"
cp "$work/office/out/config/gateway.conf" "$QL_CONFIG_ROOT/nextcloud/"
printf '%s %s\n' placeholder "$QL_CONFIG_ROOT/nextcloud/gateway.conf" >"$APP_STATE_DIR/manifest"
printf '%s %s\n' placeholder "$work/office/out/nextcloud-office.container" >>"$APP_STATE_DIR/manifest"
app_snapshot_units "$work/snapshot"
cmp "$work/snapshot/config/gateway.conf" "$QL_CONFIG_ROOT/nextcloud/gateway.conf"
cmp "$work/snapshot/nextcloud-office.container" "$work/office/out/nextcloud-office.container"
# The bridge override must reach the actual generated container file.
APP_IMAGE=docker.io/library/nextcloud:34.0.6-apache
app_render "$work/bridge" "$work/settings.env"
grep -q '^Image=docker.io/library/nextcloud:34.0.6-apache$' "$work/bridge/out/nextcloud-app.container"
echo 'Office opt-in, preserved app URL, group restart, backup layout and bridge rendering passed' 
