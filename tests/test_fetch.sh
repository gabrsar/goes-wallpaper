#!/usr/bin/env bash
# Image fetching: validation, cache naming, pruning and disk accounting.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox
. "$GOES_LIB_DIR/fetch.sh"

FIXTURES="$GOES_TESTS_DIR/fixtures"
config::load
config::set view sector
config::set satellite G19
config::set sector ssa
mkdir -p "$GOES_IMAGE_DIR"

# ── Validation ───────────────────────────────────────────────────────────────
t::case "JPEG detection"
assert_ok   "a real JPEG is recognized"     fetch::_is_jpeg "$FIXTURES/tiny.jpg"
assert_fail "HTML is rejected"              fetch::_is_jpeg "$FIXTURES/not-an-image.jpg"
assert_fail "a missing file is rejected"    fetch::_is_jpeg "$T_SANDBOX/nope.jpg"
: >"$T_SANDBOX/empty.jpg"
assert_fail "an empty file is rejected"     fetch::_is_jpeg "$T_SANDBOX/empty.jpg"

# ── Cache keys ───────────────────────────────────────────────────────────────
t::case "cache keys distinguish every view"
assert_eq 'G19_ssa_GEOCOLOR' "$(fetch::_key)" "sector keys name the sector"
config::set view fd
assert_eq 'G19_FD_GEOCOLOR' "$(fetch::_key)" "full-disk keys are distinct"
config::set view sector
config::set satellite G18
config::set sector hi
assert_eq 'G18_hi_GEOCOLOR' "$(fetch::_key)" "a different region gets a different key"
config::set satellite G19
config::set sector ssa

# ── Pruning ──────────────────────────────────────────────────────────────────
make_images() {
  local key="$1" n="$2" i=1
  rm -f "$GOES_IMAGE_DIR"/*.jpg
  while [ "$i" -le "$n" ]; do
    cp "$FIXTURES/tiny.jpg" "$GOES_IMAGE_DIR/${key}_2026010$(printf '%d' "$i")-000000.jpg"
    # Distinct mtimes so that `ls -t` has a stable order to work with.
    touch -t "2026010${i}0000" "$GOES_IMAGE_DIR/${key}_2026010$(printf '%d' "$i")-000000.jpg"
    i=$((i + 1))
  done
}
count_images() { ls "$GOES_IMAGE_DIR"/*.jpg 2>/dev/null | wc -l | tr -d ' '; }

t::case "pruning keeps the newest frames"
config::set keep_images 3
make_images G19_ssa_GEOCOLOR 7
assert_eq '7' "$(count_images)" "seven frames before pruning"
fetch::prune G19_ssa_GEOCOLOR
assert_eq '3' "$(count_images)" "three frames after pruning"
assert_file "$GOES_IMAGE_DIR/G19_ssa_GEOCOLOR_20260107-000000.jpg" "the newest frame survives"
assert_no_file "$GOES_IMAGE_DIR/G19_ssa_GEOCOLOR_20260101-000000.jpg" "the oldest frame is gone"

t::case "pruning is a no-op below the limit"
config::set keep_images 10
make_images G19_ssa_GEOCOLOR 4
fetch::prune G19_ssa_GEOCOLOR
assert_eq '4' "$(count_images)" "nothing is deleted when under the limit"

t::case "pruning only touches its own region"
config::set keep_images 2
make_images G19_ssa_GEOCOLOR 3
cp "$FIXTURES/tiny.jpg" "$GOES_IMAGE_DIR/G18_hi_GEOCOLOR_20260101-000000.jpg"
fetch::prune G19_ssa_GEOCOLOR
assert_file "$GOES_IMAGE_DIR/G18_hi_GEOCOLOR_20260101-000000.jpg" "another region's frames are left alone"

t::case "finding the newest local frame"
make_images G19_ssa_GEOCOLOR 3
assert_eq "$GOES_IMAGE_DIR/G19_ssa_GEOCOLOR_20260103-000000.jpg" "$(fetch::latest_local)" \
  "the most recent frame is returned"

t::case "disk accounting"
rm -f "$GOES_IMAGE_DIR"/*.jpg
assert_eq '0' "$(fetch::disk_usage)" "an empty cache uses no space"
make_images G19_ssa_GEOCOLOR 3
assert_eq '66' "$(fetch::disk_usage)" "three 22-byte frames total 66 bytes"

# ── Resolution resolution ────────────────────────────────────────────────────
t::case "an explicit resolution needs no network"
config::set resolution 1800x1080
assert_eq '1800x1080' "$(fetch::resolve_resolution 'https://example.invalid')" \
  "the configured resolution is used verbatim"

t::case "auto uses the cached answer when it is fresh"
config::set resolution auto
config::set max_pixels 30000000
mkdir -p "$GOES_CACHE_DIR"
printf '3600x2160\n' >"$GOES_CACHE_DIR/resolution-$(fetch::_key).30000000"
assert_eq '3600x2160' "$(fetch::resolve_resolution 'https://127.0.0.1:9/nope')" \
  "no request is made when the cache is warm"

t::case "auto reports failure when there is nothing to fall back on"
rm -f "$GOES_CACHE_DIR"/resolution-*
resolve_unreachable() {
  GOES_CONNECT_TIMEOUT=1 GOES_RETRIES=1
  fetch::resolve_resolution 'https://127.0.0.1:9/nope'
}
assert_fail "resolution discovery fails loudly" resolve_unreachable

# ── Guard rails ──────────────────────────────────────────────────────────────
t::case "fetching without configuration is refused"
CFG_satellite=''
assert_status 1 "an unconfigured fetch fails" fetch::latest

# ── Network-dependent ────────────────────────────────────────────────────────
if [ "${GOES_NETWORK_TESTS:-0}" = "1" ]; then
  t::case "live download"
  rm -f "$GOES_IMAGE_DIR"/*.jpg "$GOES_STATE_DIR"/etag-*
  config::load
  config::set view sector; config::set satellite G19; config::set sector ssa
  config::set resolution 900x540; config::set keep_images 3
  config::save
  fetch::latest
  assert_eq '0' "$?" "a frame downloads"
  assert_file "$FETCH_IMAGE" "the frame is on disk"
  assert_ok "the frame is a JPEG" fetch::_is_jpeg "$FETCH_IMAGE"
  assert_eq '900x540' "$FETCH_RESOLUTION" "the requested resolution was used"

  t::case "an unchanged frame is not downloaded twice"
  fetch::latest
  assert_eq '3' "$?" "the second fetch reports 'unchanged'"
fi

t::summary
