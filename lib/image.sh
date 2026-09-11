#!/usr/bin/env bash
# Removing the caption strip NOAA stamps along the bottom of each frame.
#
# The caption is recognised by its shape, not a fixed height, because NOAA
# sizes it differently for every resolution (14 px at 450x270, 44 px at
# 7200x4320) and the two largest full-disk frames have none at all. Reading
# upward from the bottom edge a caption is exactly: near-white padding, a band
# of text on white, near-white padding, all within the bottom 8% of the frame.
# Anything else is left untouched. share/goes-image.swift applies the same
# rule on macOS; ImageMagick does the pixel work elsewhere.

[ -n "${_GOES_IMAGE_SH:-}" ] && return 0
_GOES_IMAGE_SH=1

# shellcheck source=lib/swift.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/swift.sh"

IMAGE_PAD_PERMILLE=950      # a padding row is at least 95% near-white
IMAGE_TEXT_PERMILLE=300     # a text row is at least 30% near-white
IMAGE_WHITE_THRESHOLD='78.43%'   # 200 of 255
IMAGE_MAX_SCAN_PIXELS=200000000  # the largest frames carry no caption

IMAGE_TRIM_ROWS=0
IMAGE_TRIM_BACKEND=''

# image::caption_rows VALUE... — near-white share of each row in permille,
# bottom row first. Prints the caption height in rows, or 0.
image::caption_rows() {
  local pad="$IMAGE_PAD_PERMILLE" text="$IMAGE_TEXT_PERMILLE"
  local n=$# k=0 text_rows=0
  local rows=("$@")

  if [ "$n" -eq 0 ] || [ "${rows[0]}" -lt "$pad" ]; then printf '0'; return 0; fi
  while [ "$k" -lt "$n" ] && [ "${rows[$k]}" -ge "$pad" ]; do k=$((k + 1)); done
  if [ "$k" -ge "$n" ]; then printf '0'; return 0; fi

  while [ "$k" -lt "$n" ] && [ "${rows[$k]}" -ge "$text" ] && [ "${rows[$k]}" -lt "$pad" ]; do
    k=$((k + 1)); text_rows=$((text_rows + 1))
  done
  if [ "$k" -ge "$n" ] || [ "$text_rows" -eq 0 ] || [ "${rows[$k]}" -lt "$pad" ]; then
    printf '0'; return 0
  fi

  while [ "$k" -lt "$n" ] && [ "${rows[$k]}" -ge "$pad" ]; do k=$((k + 1)); done
  if [ "$k" -ge "$n" ]; then printf '0'; return 0; fi
  printf '%s' "$k"
}

# ── Backends ─────────────────────────────────────────────────────────────────
# Prints the ImageMagick entry point: `magick` (v7) or `convert` (v6).
image::_im() {
  if goes::have magick; then printf 'magick'
  elif goes::have convert && goes::have identify; then printf 'convert'
  else return 1
  fi
}

# Prints swift, imagemagick, or fails when neither is usable.
# GOES_IMAGE_BACKEND forces one (used by the tests to exercise both).
image::backend() {
  case "${GOES_IMAGE_BACKEND:-}" in
    swift)       [ "$GOES_PLATFORM" = "macos" ] && goes::have swiftc && { printf 'swift'; return 0; }; return 1 ;;
    imagemagick) image::_im >/dev/null && { printf 'imagemagick'; return 0; }; return 1 ;;
    none)        return 1 ;;
  esac
  if [ "$GOES_PLATFORM" = "macos" ] && { goes::have swiftc || [ -x "$(swift::helper_path goes-image)" ]; }; then
    printf 'swift'
  elif image::_im >/dev/null; then
    printf 'imagemagick'
  else
    return 1
  fi
}

# image::_im_trim IN OUT — prints rows removed; writes OUT only when > 0.
image::_im_trim() {
  local in="$1" out="$2" im dims w h band raw line y hex value
  im=$(image::_im) || return 1

  if [ "$im" = "magick" ]; then
    dims=$(magick identify -format '%w %h' "$in" 2>/dev/null) || return 1
  else
    dims=$(identify -format '%w %h' "$in" 2>/dev/null) || return 1
  fi
  w="${dims% *}"; h="${dims#* }"
  printf '%s%s' "$w" "$h" | grep -qE '^[0-9]+$' || return 1
  if [ $((w * h)) -gt "$IMAGE_MAX_SCAN_PIXELS" ]; then printf '0'; return 0; fi

  band=$((h * 8 / 100)); [ "$band" -lt 16 ] && band=16
  [ "$band" -ge "$h" ] && { printf '0'; return 0; }

  # Threshold to pure black/white, then squash each row to one pixel: its
  # value is the share of near-white pixels in that row.
  raw=$("$im" "$in" -gravity South -crop "${w}x${band}+0+0" +repage -colorspace Gray \
        -threshold "$IMAGE_WHITE_THRESHOLD" -scale "1x${band}!" -depth 16 txt:- 2>/dev/null) || return 1

  local profile=()
  while IFS= read -r line; do
    case "$line" in \#*) continue ;; esac
    y="${line#*,}"; y="${y%%:*}"
    hex=$(printf '%s' "$line" | grep -oE '#[0-9A-Fa-f]{4}' | head -1)
    [ -n "$hex" ] || continue
    value=$(( (16#${hex#\#} * 1000) / 65535 ))
    profile[$((band - 1 - y))]="$value"
  done <<EOT
$raw
EOT
  [ "${#profile[@]}" -eq "$band" ] || return 1

  local rows
  rows=$(image::caption_rows "${profile[@]}")
  if [ "$rows" -gt 0 ]; then
    "$im" "$in" -gravity South -chop "0x${rows}" -quality 92 "$out" 2>/dev/null || return 1
  fi
  printf '%s' "$rows"
}

# ── Public entry point ───────────────────────────────────────────────────────
# image::trim_caption FILE — crops the caption in place.
# Returns 0 on success (IMAGE_TRIM_ROWS may be 0: nothing to remove),
# 1 when the tool failed, 2 when no backend is available.
image::trim_caption() {
  local file="$1" backend helper tmp rows status
  IMAGE_TRIM_ROWS=0
  IMAGE_TRIM_BACKEND=''

  backend=$(image::backend) || return 2
  tmp="$file.trim.$$.jpg"

  case "$backend" in
    swift)
      helper=$(swift::helper goes-image) || return 2
      rows=$("$helper" trim-caption "$file" "$tmp" 2>/dev/null); status=$? ;;
    imagemagick)
      rows=$(image::_im_trim "$file" "$tmp"); status=$? ;;
  esac

  if [ "$status" -ne 0 ] || ! printf '%s' "$rows" | grep -qE '^[0-9]+$'; then
    rm -f "$tmp"
    goes::log warn "event=caption_trim_failed backend=$backend file=$(basename "$file")"
    return 1
  fi

  if [ "$rows" -gt 0 ]; then
    if [ ! -s "$tmp" ] || ! mv -f "$tmp" "$file"; then
      rm -f "$tmp"
      goes::log warn "event=caption_trim_failed backend=$backend reason=write file=$(basename "$file")"
      return 1
    fi
  fi
  rm -f "$tmp"
  IMAGE_TRIM_ROWS="$rows"
  IMAGE_TRIM_BACKEND="$backend"
  return 0
}

# What `doctor` and `status` report about caption trimming.
image::describe_backend() {
  case "$(image::backend 2>/dev/null)" in
    swift)       printf 'built-in (Swift)' ;;
    imagemagick) printf 'ImageMagick' ;;
    *)           return 1 ;;
  esac
}
