#!/usr/bin/env bash
# Small Swift helpers for macOS, compiled on first use and cached.
#
# Running Swift as a script costs about two seconds per call, far too slow for
# a background timer, so each helper in share/NAME.swift is built once into
# the cache and rebuilt only when its source changes.

[ -n "${_GOES_SWIFT_SH:-}" ] && return 0
_GOES_SWIFT_SH=1

# shellcheck source=lib/common.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/common.sh"

swift::helper_path() { printf '%s/bin/%s' "$GOES_CACHE_DIR" "$1"; }

# swift::helper NAME — prints the path of a ready-to-run helper, building it if
# needed. Fails when there is no Swift toolchain or the build breaks.
swift::helper() {
  local name="$1" src out
  src="$GOES_SHARE_DIR/$name.swift"
  out=$(swift::helper_path "$name")
  [ -f "$src" ] || return 1

  if [ -x "$out" ] && [ "$(goes::mtime "$out")" -ge "$(goes::mtime "$src")" ]; then
    printf '%s' "$out"
    return 0
  fi
  goes::have swiftc || return 1
  mkdir -p "$(dirname "$out")" || return 1
  if swiftc -O -o "$out.tmp.$$" "$src" >/dev/null 2>&1 && mv -f "$out.tmp.$$" "$out"; then
    goes::log info "event=swift_helper_built name=$name path=$out"
    printf '%s' "$out"
    return 0
  fi
  rm -f "$out.tmp.$$"
  goes::log error "event=swift_helper_build_failed name=$name"
  return 1
}
