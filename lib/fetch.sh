#!/usr/bin/env bash
# Downloading the latest frame for the configured region.
#
# NOAA keeps a `WIDTHxHEIGHT.jpg` file in each product directory that always
# points at the most recent frame, so no HTML scraping is needed on the hot
# path. Conditional requests mean an unchanged frame costs one small 304.

[ -n "${_GOES_FETCH_SH:-}" ] && return 0
_GOES_FETCH_SH=1

# shellcheck source=lib/catalog.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/catalog.sh"
# shellcheck source=lib/config.sh
. "${GOES_LIB_DIR}/config.sh"
# shellcheck source=lib/image.sh
. "${GOES_LIB_DIR}/image.sh"

GOES_MIN_IMAGE_BYTES=4096
GOES_RESOLUTION_CACHE_TTL=86400

FETCH_IMAGE=''
FETCH_URL=''
FETCH_RESOLUTION=''
FETCH_BYTES=0
FETCH_TRIMMED_ROWS=0

fetch::_key() {
  if [ "$CFG_view" = "fd" ]; then
    printf '%s_FD_%s' "$CFG_satellite" "$CFG_product"
  else
    printf '%s_%s_%s' "$CFG_satellite" "$CFG_sector" "$CFG_product"
  fi
}

# Resolves `auto` to a concrete WxH, caching the CDN directory listing for a
# day so the timer does not re-list on every tick.
fetch::resolve_resolution() {
  local dir_url="$1" key cache age list
  if [ "$CFG_resolution" != "auto" ]; then
    printf '%s' "$CFG_resolution"
    return 0
  fi

  key=$(fetch::_key)
  cache="$GOES_CACHE_DIR/resolution-$key.$CFG_max_pixels"
  if [ -s "$cache" ]; then
    age=$(( $(date +%s) - $(goes::mtime "$cache") ))
    if [ "$age" -lt "$GOES_RESOLUTION_CACHE_TTL" ]; then
      head -1 "$cache"
      return 0
    fi
  fi

  list=$(catalog::resolutions "$dir_url") || {
    # Fall back to the last known good value rather than failing the run.
    if [ -s "$cache" ]; then head -1 "$cache"; return 0; fi
    goes::log error "event=resolution_discovery_failed url=$dir_url"
    return 1
  }

  local chosen
  chosen=$(printf '%s\n' "$list" | catalog::pick_resolution "$CFG_max_pixels")
  [ -n "$chosen" ] || return 1
  mkdir -p "$GOES_CACHE_DIR"
  printf '%s\n' "$chosen" >"$cache"
  printf '%s' "$chosen"
}

# The resolution `auto` last resolved to, without touching the network.
fetch::cached_resolution() {
  local cache
  cache="$GOES_CACHE_DIR/resolution-$(fetch::_key).$CFG_max_pixels"
  [ -s "$cache" ] && head -1 "$cache"
}

fetch::_is_jpeg() {
  local magic
  magic=$(head -c 3 "$1" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
  [ "$magic" = "ffd8ff" ]
}

# Keeps the newest $CFG_keep_images frames for this region and deletes the rest.
fetch::prune() {
  local key="$1" keep="${CFG_keep_images:-5}" victim
  ls -t "$GOES_IMAGE_DIR/${key}_"*.jpg 2>/dev/null | tail -n +$((keep + 1)) \
  | while IFS= read -r victim; do
      [ -n "$victim" ] && rm -f "$victim"
    done
  return 0
}

fetch::latest_local() {
  local key; key=$(fetch::_key)
  ls -t "$GOES_IMAGE_DIR/${key}_"*.jpg 2>/dev/null | head -1
}

# fetch::latest
# Sets FETCH_IMAGE/FETCH_URL/FETCH_RESOLUTION/FETCH_BYTES.
# Returns 0 for a new image, 3 when the remote frame is unchanged, 1 on error.
fetch::latest() {
  config::is_configured || {
    goes::err "Not configured yet. Run: $GOES_PROG setup"
    return 1
  }
  mkdir -p "$GOES_IMAGE_DIR" "$GOES_STATE_DIR" "$GOES_CACHE_DIR" || return 1

  local dir_url key resolution url etag_file etag hdr tmp status
  dir_url=$(catalog::image_dir_url "$CFG_satellite" "$CFG_view" "$CFG_sector" "$CFG_product")
  key=$(fetch::_key)

  resolution=$(fetch::resolve_resolution "$dir_url") || {
    goes::err "Could not determine an image resolution for $(config::describe)."
    return 1
  }
  url="$dir_url/$resolution.jpg"
  FETCH_URL="$url"
  FETCH_RESOLUTION="$resolution"

  etag_file="$GOES_STATE_DIR/etag-$key"
  etag=''
  [ -f "$etag_file" ] && etag=$(head -1 "$etag_file")

  hdr=$(mktemp "${TMPDIR:-/tmp}/goes-hdr.XXXXXX") || return 1
  tmp="$GOES_IMAGE_DIR/.incoming-$key.jpg"

  local previous
  previous=$(fetch::latest_local)

  if [ -n "$etag" ] && [ -n "$previous" ] && [ -f "$previous" ]; then
    net::get "$url" "$tmp" --dump-header "$hdr" --header "If-None-Match: $etag"
  else
    net::get "$url" "$tmp" --dump-header "$hdr"
  fi
  status=$?

  if [ "$status" -eq 3 ]; then
    rm -f "$hdr" "$tmp"
    FETCH_IMAGE="$previous"
    FETCH_BYTES=$(goes::file_size "$previous")
    # Trimming is idempotent, and this covers turning trim_caption on
    # between two NOAA frames.
    fetch::_trim "$previous"
    goes::log info "event=fetch_unchanged key=$key url=$url"
    return 3
  fi

  if [ "$status" -ne 0 ]; then
    rm -f "$hdr" "$tmp"
    goes::log error "event=fetch_failed key=$key url=$url http=${NET_LAST_CODE:-000}"
    goes::err "Download failed: $url (HTTP ${NET_LAST_CODE:-000})"
    return 1
  fi

  local size
  size=$(goes::file_size "$tmp")
  if [ "$size" -lt "$GOES_MIN_IMAGE_BYTES" ]; then
    rm -f "$hdr" "$tmp"
    goes::log error "event=fetch_too_small key=$key bytes=$size url=$url"
    goes::err "NOAA returned a ${size}-byte response instead of an image."
    return 1
  fi
  if ! fetch::_is_jpeg "$tmp"; then
    rm -f "$hdr" "$tmp"
    goes::log error "event=fetch_not_jpeg key=$key bytes=$size url=$url"
    goes::err "Downloaded data is not a JPEG image."
    return 1
  fi

  local new_etag
  new_etag=$(grep -i '^etag:' "$hdr" 2>/dev/null | tail -1 | sed -E 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//' | tr -d '\r')
  rm -f "$hdr"
  if [ -n "$new_etag" ]; then
    printf '%s\n' "$new_etag" >"$etag_file"
  else
    rm -f "$etag_file"
  fi

  local final
  final="$GOES_IMAGE_DIR/${key}_$(date +%Y%m%d-%H%M%S).jpg"
  mv -f "$tmp" "$final" || {
    rm -f "$tmp"
    goes::err "Could not move the downloaded image into $GOES_IMAGE_DIR"
    return 1
  }

  FETCH_IMAGE="$final"
  FETCH_BYTES="$size"
  fetch::_trim "$final"
  fetch::prune "$key"
  goes::log info "event=fetch_ok key=$key resolution=$resolution bytes=$size file=$(basename "$final")"
  return 0
}

# Crops NOAA's caption strip when enabled. A missing tool or a failed crop
# keeps the untouched frame and is logged; the wallpaper still updates.
fetch::_trim() {
  local file="$1" status
  FETCH_TRIMMED_ROWS=0
  [ "$CFG_trim_caption" = "true" ] || return 0

  image::trim_caption "$file"; status=$?
  case "$status" in
    0) FETCH_TRIMMED_ROWS="$IMAGE_TRIM_ROWS"
       goes::log info "event=caption_trimmed rows=$IMAGE_TRIM_ROWS backend=$IMAGE_TRIM_BACKEND file=$(basename "$file")" ;;
    2) goes::log warn "event=caption_trim_unavailable reason=no_backend"
       goes::warn "Caption not removed: install ImageMagick, or run '$GOES_PROG config set trim_caption false'." ;;
    *) goes::warn "Caption not removed: cropping failed (see '$GOES_PROG log'). Using the frame as is." ;;
  esac
  return 0
}

fetch::disk_usage() {
  local total=0 f
  for f in "$GOES_IMAGE_DIR"/*.jpg; do
    [ -f "$f" ] || continue
    total=$((total + $(goes::file_size "$f")))
  done
  printf '%s' "$total"
}
