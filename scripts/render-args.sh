# shellcheck shell=bash
# Shared with the real installer and Quadlet dry-run fixtures.
render_args() {
  local enabled bind port origin authority
  enabled=$(ql_env_get WOOW_OFFICE_ENABLED 0)
  ql_assert_match WOOW_OFFICE_ENABLED "$enabled" '0|1'
  bind=$(ql_env_get OFFICE_BIND 127.0.0.1)
  port=$(ql_env_get OFFICE_PORT 18081)
  origin=$(ql_env_get OFFICE_ORIGIN http://localhost:18081)
  ql_assert_match OFFICE_BIND "$bind" '[0-9]{1,3}(\.[0-9]{1,3}){3}|\[[0-9A-Fa-f:.]+\]'
  ql_assert_match OFFICE_PORT "$port" '[0-9]{1,5}'
  ((10#$port >= 1 && 10#$port <= 65535)) || ql_die 'OFFICE_PORT is not a TCP port'
  ql_assert_match OFFICE_ORIGIN "$origin" 'https?://([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?'
  authority=${origin#*://}
  if [[ $enabled == 1 && $port == "$(ql_env_get HOST_PORT)" ]]; then
    ql_die 'OFFICE_PORT must differ from HOST_PORT; the original app entry is preserved'
  fi
  # shellcheck disable=SC2034 # consumed by ql_render in the caller
  RENDER_ARGS=("OFFICE_BIND=$bind" "OFFICE_PORT=$port" "OFFICE_ORIGIN=$origin" "OFFICE_AUTHORITY=$authority")
}
