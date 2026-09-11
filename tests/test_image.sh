#!/usr/bin/env bash
# Caption-strip removal: the detection rule on synthetic row profiles, then
# every available backend against real NOAA frames.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox
. "$GOES_LIB_DIR/fetch.sh"

FIXTURES="$GOES_TESTS_DIR/fixtures"

# ── The rule ─────────────────────────────────────────────────────────────────
# Profiles are the near-white share of each row in permille, bottom row first.
t::case "a caption is padding, text, padding"
assert_eq '7' "$(image::caption_rows 1000 1000 900 850 900 1000 1000 20 20 20)" \
  "the whole strip, both paddings included, is measured"
assert_eq '4' "$(image::caption_rows 950 300 950 950 0 0 0)" \
  "thresholds are inclusive at 95% and 30%"

t::case "anything else is left alone"
assert_eq '0' "$(image::caption_rows 1000 1000 1000 1000 1000 1000)" \
  "an all-white bottom (no text band, no edge) is not a caption"
assert_eq '0' "$(image::caption_rows 100 1000 900 1000 20)" \
  "a bottom row that is not white means no caption"
assert_eq '0' "$(image::caption_rows 1000 1000 20 20 20)" \
  "padding with no text band is not a caption"
assert_eq '0' "$(image::caption_rows 1000 900 900 100 1000 20)" \
  "text that fades into imagery without top padding is not a caption"
assert_eq '0' "$(image::caption_rows 1000 600 600 600 600 600)" \
  "bright clouds with no top padding before the scan limit are not a caption"
assert_eq '0' "$(image::caption_rows 1000 900 1000 1000)" \
  "a caption that runs to the scan limit is not trusted"
assert_eq '0' "$(image::caption_rows)" "an empty profile is handled"

# ── Backends against real frames ─────────────────────────────────────────────
height_of() {
  if command -v sips >/dev/null 2>&1; then
    sips -g pixelHeight "$1" 2>/dev/null | awk '/pixelHeight/ {print $2}'
  elif command -v magick >/dev/null 2>&1; then
    magick identify -format '%h' "$1"
  elif command -v identify >/dev/null 2>&1; then
    identify -format '%h' "$1"
  fi
}

check_backend() {
  local backend="$1" f expect orig_h new_h
  export GOES_IMAGE_BACKEND="$backend"

  t::case "$backend: captions are removed from real NOAA frames"
  for spec in caption-sector-450x270:14 caption-fulldisk-678x678:16 caption-pnw-600x600:16; do
    f="$T_SANDBOX/${spec%%:*}.jpg"; expect="${spec#*:}"
    cp "$FIXTURES/${spec%%:*}.jpg" "$f"
    orig_h=$(height_of "$f")
    image::trim_caption "$f"
    assert_eq '0' "$?" "$backend trims ${spec%%:*}"
    assert_eq "$expect" "$IMAGE_TRIM_ROWS" "$backend finds the ${expect}-row caption on ${spec%%:*}"
    new_h=$(height_of "$f")
    if [ -n "$orig_h" ] && [ -n "$new_h" ]; then
      assert_eq "$((orig_h - expect))" "$new_h" "$backend writes the shorter frame in place"
    fi
    assert_ok "$backend output is still a JPEG" fetch::_is_jpeg "$f"
  done

  t::case "$backend: frames without a caption are untouched"
  for name in nocaption-sector-450x256 all-white-240x120; do
    f="$T_SANDBOX/$name.jpg"
    cp "$FIXTURES/$name.jpg" "$f"
    image::trim_caption "$f"
    assert_eq '0' "$IMAGE_TRIM_ROWS" "$backend leaves $name alone"
    if cmp -s "$f" "$FIXTURES/$name.jpg"; then
      t::_pass "$backend does not rewrite $name"
    else
      t::_fail "$backend does not rewrite $name" "file changed"
    fi
  done

  t::case "$backend: trimming twice changes nothing"
  f="$T_SANDBOX/twice.jpg"
  cp "$FIXTURES/caption-sector-450x270.jpg" "$f"
  image::trim_caption "$f"
  image::trim_caption "$f"
  assert_eq '0' "$IMAGE_TRIM_ROWS" "$backend finds nothing on a second pass"

  unset GOES_IMAGE_BACKEND
}

ran=0
if [ "$GOES_PLATFORM" = "macos" ] && command -v swiftc >/dev/null 2>&1; then
  check_backend swift; ran=1
fi
if command -v magick >/dev/null 2>&1 || { command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; }; then
  check_backend imagemagick; ran=1
fi
[ "$ran" -eq 0 ] && t::_pass "skipped: no image backend (Swift or ImageMagick) installed"

# ── Integration ──────────────────────────────────────────────────────────────
t::case "no backend is reported, not hidden"
export GOES_IMAGE_BACKEND=none
f="$T_SANDBOX/none.jpg"
cp "$FIXTURES/caption-sector-450x270.jpg" "$f"
image::trim_caption "$f"
assert_eq '2' "$?" "trim_caption returns 2 when no tool is available"
config::load
CFG_trim_caption=true
out=$(fetch::_trim "$f" 2>&1)
assert_contains "$out" "install ImageMagick" "the fetch step tells the user how to fix it"
assert_contains "$(cat "$GOES_STATE_HOME/goes-wallpaper.log")" "event=caption_trim_unavailable" \
  "the log records it"
assert_eq '' "$(image::describe_backend)" "doctor has nothing to name"
unset GOES_IMAGE_BACKEND

t::case "trimming can be turned off"
config::load
CFG_trim_caption=false
f="$T_SANDBOX/off.jpg"
cp "$FIXTURES/caption-sector-450x270.jpg" "$f"
fetch::_trim "$f"
if cmp -s "$f" "$FIXTURES/caption-sector-450x270.jpg"; then
  t::_pass "the frame is untouched when trim_caption=false"
else
  t::_fail "the frame is untouched when trim_caption=false"
fi

t::case "the setting is validated"
assert_ok   "true is accepted"  config::validate trim_caption true
assert_ok   "false is accepted" config::validate trim_caption false
assert_fail "yes is rejected"   config::validate trim_caption yes

t::summary
