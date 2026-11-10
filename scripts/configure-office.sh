#!/usr/bin/env bash
# Install the persistent richdocuments app and connect it to same-origin Collabora.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
. "$REPO/scripts/lib/quadlet-lib.sh"
. "$REPO/scripts/app.sh"
ql_env_load "$ENV_FILE"
app_wait_status 900 || ql_die "Nextcloud is not ready for Office configuration"

discovery_url="$(app_base_url)/hosting/discovery"
ready=0
for ((attempt=0; attempt<120; attempt++)); do
  discovery=$(curl -fsS -m 10 "$discovery_url" 2>/dev/null || true)
  if [[ $discovery == *'<wopi-discovery'* ]]; then ready=1; break; fi
  sleep 5
done
((ready)) || ql_die "Collabora discovery did not become ready at $discovery_url"

if ! app_occ app:getpath richdocuments >/dev/null 2>&1; then
  app_occ app:install richdocuments
fi
app_occ app:enable richdocuments >/dev/null
public_url=$(ql_env_get NEXTCLOUD_PUBLIC_URL)
# Office is on a private bridge; Nextcloud must permit fetching its discovery URL.
app_occ config:system:set allow_local_remote_servers --type boolean --value true >/dev/null
app_occ config:app:set richdocuments wopi_url --value http://nextcloud-office:9980 >/dev/null
app_occ richdocuments:activate-config >/dev/null
app_occ config:app:set richdocuments public_wopi_url --value "$public_url" >/dev/null
app_occ config:app:set richdocuments wopi_callback_url --value "$public_url" >/dev/null
app_occ config:system:set overwrite.cli.url --value "$public_url" >/dev/null
app_occ config:system:set default_phone_region --value "$(ql_env_get DEFAULT_PHONE_REGION TW)" >/dev/null
app_occ config:system:set maintenance_window_start --type integer --value 1 >/dev/null
app_occ config:app:set password_policy minLength --value 7 >/dev/null
app_occ app:disable firstrunwizard >/dev/null 2>&1 || true
ql_info "Office is configured for $public_url"
