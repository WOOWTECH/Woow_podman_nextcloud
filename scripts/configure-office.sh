#!/usr/bin/env bash
# Explicit activation after install.sh with WOOW_OFFICE_ENABLED=1.
# Installs only the reviewed Office app, never updates unrelated apps.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=app.sh
. "$REPO/scripts/app.sh"
ql_require_rootless
ql_lock "$APP"
app_require_installed
ql_env_load "$ENV_FILE"
app_validate_env
app_office_enabled || ql_die 'Set WOOW_OFFICE_ENABLED=1 and run install.sh first'
systemctl --user is-active --quiet nextcloud-office.service nextcloud-gateway.service \
  || ql_die 'Office and its gateway must be running first'
python3 "$REPO/scripts/nextcloud-office-app.py" "$@"
origin=$(ql_env_get OFFICE_ORIGIN http://localhost:18081)
app_occ config:app:set richdocuments wopi_url "--value=$origin"
app_occ config:app:set richdocuments public_wopi_url "--value=$origin"
ql_info 'Office configured; verify opening and saving a document through the gateway URL'
