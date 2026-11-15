#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../scripts/lib/quadlet-lib.sh
. "$REPO/scripts/lib/quadlet-lib.sh"
# shellcheck source=../scripts/app.sh
. "$REPO/scripts/app.sh"
app_validate_transition 34.0.3 34.0.6
app_validate_transition 34.0.6 35.0.3
app_validate_transition 35.0.1 35.0.3
app_validate_transition 35.0.3 35.0.3
for pair in '34.0.3 35.0.3' '33.0.6 35.0.3' '35.0.3 35.0.1'; do
  read -r cur tgt <<<"$pair"
  if (app_validate_transition "$cur" "$tgt") >/dev/null 2>&1; then
    echo "Unsafe transition accepted: $pair" >&2; exit 1
  fi
done
echo 'Supported bridge, no-major-skip and downgrade refusal passed'
