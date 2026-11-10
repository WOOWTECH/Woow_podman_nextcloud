#!/usr/bin/env bash
# Build the small Nextcloud extension image when it is missing on this host.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
. "$REPO/scripts/lib/quadlet-lib.sh"
. "$REPO/scripts/app.sh"
if podman image exists "$APP_IMAGE"; then
  ql_info "$APP_IMAGE is cached"
  exit 0
fi
ql_info "building $APP_IMAGE from the pinned Nextcloud base"
podman build --pull=missing -t "$APP_IMAGE" -f "$REPO/Containerfile" "$REPO"
