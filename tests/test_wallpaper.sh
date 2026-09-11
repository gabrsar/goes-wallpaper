#!/usr/bin/env bash
# Wallpaper backends: option mapping, platform dispatch and power detection.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox
. "$GOES_LIB_DIR/wallpaper.sh"

FIXTURES="$GOES_TESTS_DIR/fixtures"

t::case "platform detection"
case "$GOES_PLATFORM" in
  macos|linux) t::_pass "platform resolved to $GOES_PLATFORM" ;;
  *) t::_fail "platform resolved" "got '$GOES_PLATFORM'" ;;
esac

t::case "freedesktop picture-options mapping"
assert_eq 'scaled'    "$(wallpaper::_gnome_picture_option fit)"     "fit maps to scaled"
assert_eq 'zoom'      "$(wallpaper::_gnome_picture_option fill)"    "fill maps to zoom"
assert_eq 'centered'  "$(wallpaper::_gnome_picture_option center)"  "center maps to centered"
assert_eq 'stretched' "$(wallpaper::_gnome_picture_option stretch)" "stretch maps to stretched"
assert_eq 'scaled'    "$(wallpaper::_gnome_picture_option '')"      "an unset mode falls back to scaled"

t::case "a missing image is refused before touching any backend"
assert_status 1 "setting a nonexistent file fails" wallpaper::set "$T_SANDBOX/nope.jpg" fit
assert_contains "$(wallpaper::set "$T_SANDBOX/nope.jpg" fit 2>&1)" "image not found" \
  "the error names the problem"

t::case "a custom wallpaper command takes precedence"
: >"$GOES_WALLPAPER_LOG"
wallpaper::set "$FIXTURES/tiny.jpg" fit
assert_eq '0' "$?" "the custom command succeeds"
assert_eq 'custom' "$WALLPAPER_BACKEND" "the backend is reported as custom"
assert_eq "$FIXTURES/tiny.jpg" "$(cat "$GOES_WALLPAPER_LOG")" "the image path is passed as the last argument"

t::case "a failing custom command is reported, not hidden"
assert_status 1 "a failing command fails the update" env GOES_WALLPAPER_CMD=false \
  "$BASH" -c ". '$GOES_LIB_DIR/wallpaper.sh'; wallpaper::set '$FIXTURES/tiny.jpg' fit"
out=$(GOES_WALLPAPER_CMD=false "$BASH" -c ". '$GOES_LIB_DIR/wallpaper.sh'; wallpaper::set '$FIXTURES/tiny.jpg' fit" 2>&1)
assert_contains "$out" "GOES_WALLPAPER_CMD failed" "the error names the command"

t::case "power detection returns a definite answer"
if wallpaper::on_ac_power; then
  t::_pass "on AC power"
else
  t::_pass "on battery power"
fi

t::case "display geometry"
screen=$(wallpaper::screen_size)
if [ -z "$screen" ]; then
  t::_pass "no display detected (headless); recommendations will be skipped"
else
  printf '%s' "$screen" | grep -qE '^[0-9]+x[0-9]+$' \
    && t::_pass "display reported as $screen" \
    || t::_fail "display geometry is WxH" "got '$screen'"
fi

if [ "$GOES_PLATFORM" = "macos" ]; then
  t::case "the Swift helper source is present and compiles"
  assert_file "$GOES_SHARE_DIR/set-wallpaper.swift" "the helper source ships with the project"
  if command -v swiftc >/dev/null 2>&1; then
    if swiftc -O -o "$T_SANDBOX/helper" "$GOES_SHARE_DIR/set-wallpaper.swift" 2>"$T_SANDBOX/swift.err"; then
      t::_pass "the helper compiles"
      out=$("$T_SANDBOX/helper" 2>&1); status=$?
      assert_eq '64' "$status" "no arguments is a usage error"
      assert_contains "$out" "usage" "usage is printed"
      "$T_SANDBOX/helper" "$T_SANDBOX/missing.jpg" >/dev/null 2>&1
      assert_eq '66' "$?" "a missing file reports EX_NOINPUT"
    else
      t::_fail "the helper compiles" "$(head -3 "$T_SANDBOX/swift.err")"
    fi
  else
    t::_pass "skipped: swiftc is not installed"
  fi

  t::case "the compiled helper is cached next to the other caches"
  assert_contains "$(wallpaper::_mac_helper_path)" "$GOES_CACHE_DIR" \
    "the helper lives under the cache directory"
fi

if [ "$GOES_PLATFORM" = "linux" ]; then
  t::case "desktop identification is lowercased"
  XDG_CURRENT_DESKTOP='GNOME' assert_eq 'gnome' "$(XDG_CURRENT_DESKTOP=GNOME wallpaper::_desktop_id)" \
    "GNOME normalizes to gnome"
  assert_eq '' "$(XDG_CURRENT_DESKTOP='' XDG_SESSION_DESKTOP='' wallpaper::_desktop_id)" \
    "an unset desktop yields an empty id"
fi

t::summary
