#!/usr/bin/env bash
# Configuration: a single validated key=value file at $GOES_CONFIG_FILE.
#
# The file is parsed line by line against a whitelist rather than sourced, so a
# corrupted or hand-edited config can never execute code.

[ -n "${_GOES_CONFIG_SH:-}" ] && return 0
_GOES_CONFIG_SH=1

# shellcheck source=lib/common.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/common.sh"

GOES_CONFIG_KEYS="view satellite sector product resolution max_pixels interval on_battery keep_images scaling"

CFG_view=''
CFG_satellite=''
CFG_sector=''
CFG_product='GEOCOLOR'
CFG_resolution='auto'
CFG_max_pixels='0'
CFG_interval='10'
CFG_on_battery='skip'
CFG_keep_images='5'
CFG_scaling='fit'

config::_default_for() {
  case "$1" in
    view)           printf 'sector' ;;
    satellite)      printf '' ;;
    sector)         printf '' ;;
    product)        printf 'GEOCOLOR' ;;
    resolution)     printf 'auto' ;;
    max_pixels)     printf '0' ;;
    interval)       printf '10' ;;
    on_battery)     printf 'skip' ;;
    keep_images)    printf '5' ;;
    scaling)        printf 'fit' ;;
    *)              printf '' ;;
  esac
}

config::is_key() {
  case " $GOES_CONFIG_KEYS " in
    *" $1 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# Returns 0 when $2 is an acceptable value for key $1, else 1 with a message on
# stderr describing the accepted form.
config::validate() {
  local key="$1" value="$2"
  case "$key" in
    view)
      case "$value" in fd|sector) return 0 ;; esac
      goes::err "view must be 'fd' (full disk) or 'sector'; got '$value'" ;;
    satellite)
      # Empty means "not chosen yet"; config::is_configured is what enforces it.
      [ -z "$value" ] && return 0
      printf '%s' "$value" | grep -qE '^G[0-9]{2}$' && return 0
      goes::err "satellite must look like G16..G19; got '$value'" ;;
    sector)
      [ -z "$value" ] && return 0
      printf '%s' "$value" | grep -qE '^[a-z]{2,6}$' && return 0
      goes::err "sector must be 2-6 lowercase letters; got '$value'" ;;
    product)
      printf '%s' "$value" | grep -qE '^[A-Za-z0-9_-]{2,24}$' && return 0
      goes::err "product must be alphanumeric; got '$value'" ;;
    resolution)
      [ "$value" = "auto" ] && return 0
      printf '%s' "$value" | grep -qE '^[0-9]{2,6}x[0-9]{2,6}$' && return 0
      goes::err "resolution must be 'auto' or WIDTHxHEIGHT; got '$value'" ;;
    max_pixels)
      printf '%s' "$value" | grep -qE '^[0-9]{1,12}$' && return 0
      goes::err "max_pixels must be a whole number of pixels (0 = no limit); got '$value'" ;;
    interval)
      printf '%s' "$value" | grep -qE '^[0-9]{1,4}$' \
        && [ "$value" -ge 1 ] && [ "$value" -le 1440 ] && return 0
      goes::err "interval must be 1-1440 minutes; got '$value'" ;;
    scaling)
      case "$value" in fit|fill|stretch|center) return 0 ;; esac
      goes::err "scaling must be fit, fill, stretch or center; got '$value'" ;;
    on_battery)
      case "$value" in skip|run) return 0 ;; esac
      goes::err "on_battery must be 'skip' or 'run'; got '$value'" ;;
    keep_images)
      printf '%s' "$value" | grep -qE '^[0-9]{1,3}$' \
        && [ "$value" -ge 1 ] && [ "$value" -le 200 ] && return 0
      goes::err "keep_images must be 1-200; got '$value'" ;;
    *)
      goes::err "unknown configuration key '$key'" ;;
  esac
  return 1
}

config::get() {
  local key="$1"
  config::is_key "$key" || { goes::err "unknown configuration key '$key'"; return 1; }
  eval "printf '%s' \"\${CFG_$key}\""
}

config::set() {
  local key="$1" value="$2"
  config::is_key "$key" || { goes::err "unknown configuration key '$key'"; return 1; }
  config::validate "$key" "$value" || return 1
  eval "CFG_$key=\$value"
}

# Loads config into CFG_* variables. Missing file is not an error: callers use
# config::is_configured to decide whether setup has been run.
config::load() {
  local file="${1:-$GOES_CONFIG_FILE}"
  local key
  for key in $GOES_CONFIG_KEYS; do
    eval "CFG_$key=\$(config::_default_for \"\$key\")"
  done

  [ -f "$file" ] || return 0

  local line lineno=0 raw_key raw_value
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    # Trim surrounding whitespace without invoking a subshell per line.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue

    case "$line" in
      *=*) ;;
      *) goes::warn "$file:$lineno: ignoring malformed line '$line'"; continue ;;
    esac

    raw_key="${line%%=*}"
    raw_value="${line#*=}"
    raw_key="${raw_key%"${raw_key##*[![:space:]]}"}"
    raw_value="${raw_value#"${raw_value%%[![:space:]]*}"}"
    # Strip one layer of optional quoting.
    case "$raw_value" in
      \"*\") raw_value="${raw_value#\"}"; raw_value="${raw_value%\"}" ;;
      \'*\') raw_value="${raw_value#\'}"; raw_value="${raw_value%\'}" ;;
    esac

    if ! config::is_key "$raw_key"; then
      goes::warn "$file:$lineno: ignoring unknown key '$raw_key'"
      continue
    fi
    if ! config::validate "$raw_key" "$raw_value" 2>/dev/null; then
      goes::warn "$file:$lineno: ignoring invalid value for '$raw_key' ('$raw_value'); using default"
      continue
    fi
    eval "CFG_$raw_key=\$raw_value"
  done <"$file"
}

config::save() {
  local file="${1:-$GOES_CONFIG_FILE}"
  local dir tmp
  dir="$(dirname "$file")"
  mkdir -p "$dir" || { goes::err "cannot create $dir"; return 1; }
  tmp="$file.tmp.$$"

  {
    printf '# goes-wallpaper configuration\n'
    printf '# Written %s. Edit freely, or use `%s config set KEY VALUE`.\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$GOES_PROG"
    printf '\n'
    printf '# fd = full disk (whole Earth), sector = regional close-up\n'
    printf 'view=%s\n' "$CFG_view"
    printf 'satellite=%s\n' "$CFG_satellite"
    printf 'sector=%s\n' "$CFG_sector"
    printf 'product=%s\n' "$CFG_product"
    printf '\n'
    printf '# auto = largest image available (capped by max_pixels when it is not 0)\n'
    printf 'resolution=%s\n' "$CFG_resolution"
    printf 'max_pixels=%s\n' "$CFG_max_pixels"
    printf '\n'
    printf '# minutes between refreshes (NOAA publishes new imagery every ~10 min)\n'
    printf 'interval=%s\n' "$CFG_interval"
    printf 'on_battery=%s\n' "$CFG_on_battery"
    printf 'keep_images=%s\n' "$CFG_keep_images"
    printf '\n'
    printf '# fit keeps the whole frame on a black field; fill crops to the screen\n'
    printf 'scaling=%s\n' "$CFG_scaling"
  } >"$tmp" || { rm -f "$tmp"; goes::err "cannot write $tmp"; return 1; }

  mv -f "$tmp" "$file" || { rm -f "$tmp"; goes::err "cannot move config into place"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
}

config::has_region() {
  [ -n "$CFG_satellite" ] || return 1
  [ "$CFG_view" = "fd" ] || [ -n "$CFG_sector" ] || return 1
  return 0
}

config::is_configured() {
  [ -f "$GOES_CONFIG_FILE" ] && config::has_region
}

config::describe() {
  if [ "$CFG_view" = "fd" ]; then
    printf '%s full disk' "$CFG_satellite"
  else
    printf '%s sector %s' "$CFG_satellite" "$CFG_sector"
  fi
}

# ── Migration from the pre-2.0 layout ────────────────────────────────────────
# v1 stored one value per file in ~/.config/goes-*. Import them once so an
# upgrade keeps the user's existing region instead of silently resetting it.
GOES_LEGACY_FILES="goes-sat goes-sector goes-resolution goes-interval goes-keep-images"

config::legacy_present() {
  local base="${XDG_CONFIG_HOME:-$HOME/.config}" f
  for f in $GOES_LEGACY_FILES; do
    [ -f "$base/$f" ] && return 0
  done
  return 1
}

config::migrate_legacy() {
  local base="${XDG_CONFIG_HOME:-$HOME/.config}"
  config::legacy_present || return 1

  local sat sector res interval keep
  # v1 sometimes wrote raw query-string fragments; keep only the leading token.
  sat=$(sed -e 's/&.*//' -e 's/[^A-Za-z0-9]*$//' "$base/goes-sat" 2>/dev/null | head -1)
  sector=$(sed -e 's/&.*//' -e 's/[^A-Za-z0-9]*$//' "$base/goes-sector" 2>/dev/null | head -1)
  res=$(head -1 "$base/goes-resolution" 2>/dev/null | tr -d ' ')
  interval=$(head -1 "$base/goes-interval" 2>/dev/null | tr -d ' ')
  keep=$(head -1 "$base/goes-keep-images" 2>/dev/null | tr -d ' ')

  CFG_view='sector'
  [ -n "$sat" ] && config::set satellite "$sat" 2>/dev/null
  [ -n "$sector" ] && config::set sector "$sector" 2>/dev/null
  [ "$res" = "largest" ] && res="auto"
  [ -n "$res" ] && config::set resolution "$res" 2>/dev/null
  [ -n "$interval" ] && config::set interval "$interval" 2>/dev/null
  [ -n "$keep" ] && config::set keep_images "$keep" 2>/dev/null

  config::has_region || { config::load; return 1; }
  return 0
}

config::archive_legacy() {
  local base="${XDG_CONFIG_HOME:-$HOME/.config}" f dest="$GOES_CONFIG_DIR/legacy-v1"
  config::legacy_present || return 0
  mkdir -p "$dest" || return 0
  for f in $GOES_LEGACY_FILES; do
    [ -f "$base/$f" ] && mv -f "$base/$f" "$dest/$f" 2>/dev/null
  done
  goes::hint "Old v1 config files moved to $dest"
}
