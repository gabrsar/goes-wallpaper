#!/usr/bin/env bash
# The result of the most recent update, so that `status` and `doctor` can say
# something useful without touching the network.

[ -n "${_GOES_STATE_SH:-}" ] && return 0
_GOES_STATE_SH=1

# shellcheck source=lib/common.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/common.sh"

ST_last_run=0
ST_last_status='never'
ST_last_image=''
ST_last_detail=''

# state::write STATUS [IMAGE] [DETAIL]
# STATUS is one of: ok, unchanged, skipped, error.
state::write() {
  mkdir -p "$GOES_STATE_DIR" 2>/dev/null || return 0
  {
    printf 'last_run=%s\n' "$(date +%s)"
    printf 'last_status=%s\n' "$1"
    printf 'last_image=%s\n' "${2:-}"
    printf 'last_detail=%s\n' "${3:-}"
  } >"$GOES_STATUS_FILE" 2>/dev/null || true
}

state::read() {
  ST_last_run=0; ST_last_status='never'; ST_last_image=''; ST_last_detail=''
  [ -f "$GOES_STATUS_FILE" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      last_run|last_status|last_image|last_detail) eval "ST_$key=\$value" ;;
    esac
  done <"$GOES_STATUS_FILE"
  printf '%s' "$ST_last_run" | grep -qE '^[0-9]+$' || ST_last_run=0
}
