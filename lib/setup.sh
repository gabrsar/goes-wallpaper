#!/usr/bin/env bash
# The interactive first-run wizard.
#
# Five short steps, each one a keyboard-driven picker with live data from
# NOAA. Everything degrades to numbered prompts when there is no terminal.

[ -n "${_GOES_SETUP_SH:-}" ] && return 0
_GOES_SETUP_SH=1

# shellcheck source=lib/ui.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/ui.sh"
# shellcheck source=lib/fetch.sh
. "${GOES_LIB_DIR}/fetch.sh"
# shellcheck source=lib/wallpaper.sh
. "${GOES_LIB_DIR}/wallpaper.sh"
# shellcheck source=lib/service.sh
. "${GOES_LIB_DIR}/service.sh"

SETUP_STEP=0
SETUP_TOTAL=5

setup::_step() {
  SETUP_STEP=$((SETUP_STEP + 1))
  printf '\n%s%sStep %s/%s%s  %s%s%s\n' \
    "$C_BOLD" "$C_CYAN" "$SETUP_STEP" "$SETUP_TOTAL" "$C_RESET" \
    "$C_BOLD" "$1" "$C_RESET" >&2
}

# ── Step 1: what to look at ──────────────────────────────────────────────────
# Full-disk views and regional sectors live in one filterable list, so picking
# "South America" is two keystrokes rather than a walk through sub-menus.
SETUP_VIEW=''; SETUP_SAT=''; SETUP_SECTOR=''; SETUP_LABEL=''

setup::choose_region() {
  setup::_step "Choose what you want on your desktop"

  ui::spin_start "Asking NOAA which regions are available"
  catalog::load --refresh
  if [ "$CAT_COUNT" -eq 0 ]; then
    ui::spin_stop 1 "Could not read the NOAA region list"
    return 1
  fi
  case "$CAT_SOURCE" in
    noaa)    ui::spin_stop 0 "$CAT_COUNT regions available from NOAA" ;;
    cache)   ui::spin_stop 0 "$CAT_COUNT regions (cached)" ;;
    builtin) ui::spin_stop 0 "$CAT_COUNT regions (offline list; NOAA unreachable)" ;;
  esac

  UI_ITEMS=(); UI_HINTS=(); UI_GROUPS=()
  local n=0 sat i initial=0

  # Full-disk entries first: they are what most people actually want.
  for sat in $(catalog::satellites); do
    UI_ITEMS[$n]="Whole Earth $GOES_GLYPH_DOT $(catalog::sat_label "$sat")"
    UI_HINTS[$n]="$sat $GOES_GLYPH_DOT $(catalog::sat_position "$sat")"
    UI_GROUPS[$n]="Full disk"
    SETUP_OPT_VIEW[$n]='fd'; SETUP_OPT_SAT[$n]="$sat"; SETUP_OPT_SECTOR[$n]=''
    SETUP_OPT_LABEL[$n]="$(catalog::sat_label "$sat") full disk"
    n=$((n + 1))
  done

  i=0
  while [ "$i" -lt "$CAT_COUNT" ]; do
    UI_ITEMS[$n]="${CAT_NAME[$i]}"
    UI_HINTS[$n]="$(catalog::sat_label "${CAT_SAT[$i]}") $GOES_GLYPH_DOT ${CAT_SECTOR[$i]}"
    UI_GROUPS[$n]="${CAT_GROUP[$i]}"
    SETUP_OPT_VIEW[$n]='sector'
    SETUP_OPT_SAT[$n]="${CAT_SAT[$i]}"
    SETUP_OPT_SECTOR[$n]="${CAT_SECTOR[$i]}"
    SETUP_OPT_LABEL[$n]="${CAT_NAME[$i]}"
    if [ "${CAT_SAT[$i]}" = "$CFG_satellite" ] && [ "${CAT_SECTOR[$i]}" = "$CFG_sector" ]; then
      initial="$n"
    fi
    n=$((n + 1)); i=$((i + 1))
  done

  UI_TITLE="Which view?"
  UI_SUBTITLE="Type to filter $GOES_GLYPH_DOT full disk shows the entire hemisphere, sectors zoom in"
  UI_INITIAL="$initial"
  ui::select || return 1

  SETUP_VIEW="${SETUP_OPT_VIEW[$UI_RESULT]}"
  SETUP_SAT="${SETUP_OPT_SAT[$UI_RESULT]}"
  SETUP_SECTOR="${SETUP_OPT_SECTOR[$UI_RESULT]}"
  SETUP_LABEL="${SETUP_OPT_LABEL[$UI_RESULT]}"

  goes::ok "$SETUP_LABEL $C_GREY($(catalog::sat_label "$SETUP_SAT"), $SETUP_SAT)$C_RESET"
  return 0
}
SETUP_OPT_VIEW=(); SETUP_OPT_SAT=(); SETUP_OPT_SECTOR=(); SETUP_OPT_LABEL=()

# ── Step 2: resolution ───────────────────────────────────────────────────────
SETUP_RESOLUTION=''

setup::_megapixels() {
  local w="${1%x*}" h="${1#*x}" mp
  mp=$(( (w * h) / 100000 ))
  printf '%s.%s MP' "$((mp / 10))" "$((mp % 10))"
}

# setup::_res_hint RESOLUTION SIZES_TSV  — "7.7 MP · 5.6 MB"
setup::_res_hint() {
  local res="$1" sizes="$2" bytes
  bytes=$(printf '%s' "$sizes" | grep "^$res	" | cut -f2)
  printf '%s%s' "$(setup::_megapixels "$res")" "${bytes:+ $GOES_GLYPH_DOT $(goes::human_bytes "$bytes")}"
}

setup::choose_resolution() {
  setup::_step "Pick an image size"

  local dir_url screen screen_w
  dir_url=$(catalog::image_dir_url "$SETUP_SAT" "$SETUP_VIEW" "$SETUP_SECTOR" "$CFG_product")

  ui::spin_start "Measuring your display and listing available sizes"
  screen=$(wallpaper::screen_size)
  screen_w="${screen%x*}"
  printf '%s' "$screen_w" | grep -qE '^[0-9]+$' || screen_w=0

  local list
  if ! list=$(catalog::resolutions "$dir_url"); then
    ui::spin_stop 1 "Could not list sizes; falling back to automatic"
    SETUP_RESOLUTION='auto'
    return 0
  fi
  ui::spin_stop 0 "Sizes available${screen:+ (your display: $screen)}"

  # The smallest image that still covers the display width is the sweet spot:
  # sharp, but not a 200 MB download every ten minutes.
  local pixels res recommended='' rev
  rev=$(printf '%s\n' "$list" | LC_ALL=C sort -n)
  while IFS='	' read -r pixels res; do
    [ -z "$res" ] && continue
    if [ "$screen_w" -gt 0 ] && [ "${res%x*}" -ge "$screen_w" ] && [ -z "$recommended" ]; then
      recommended="$res"
    fi
  done <<EOT
$rev
EOT
  [ -z "$recommended" ] && recommended=$(printf '%s\n' "$list" | head -1 | cut -f2)

  ui::spin_start "Checking download sizes"
  local sizes='' bytes
  while IFS='	' read -r pixels res; do
    [ -z "$res" ] && continue
    bytes=$(net::content_length "$dir_url/$res.jpg" 2>/dev/null) || bytes=''
    sizes="$sizes$res	$bytes"$'\n'
  done <<EOT
$list
EOT
  ui::spin_stop 0 "Download sizes checked"

  local auto_pick
  auto_pick=$(printf '%s\n' "$list" | catalog::pick_resolution "$CFG_max_pixels")

  # Recommended choices first, then every size largest to smallest.
  UI_ITEMS=(); UI_HINTS=(); UI_GROUPS=(); SETUP_RES_OPT=()
  local n=0 initial=0
  UI_ITEMS[0]="Automatic"
  UI_HINTS[0]="now $auto_pick, adjusts itself"
  UI_GROUPS[0]="Recommended"
  SETUP_RES_OPT[0]='auto'
  n=1

  # Only recommend a size when the display was measured; otherwise the
  # "recommendation" would just be the largest file.
  local show_recommended=0
  [ "$screen_w" -gt 0 ] && [ -n "$recommended" ] && show_recommended=1

  if [ "$show_recommended" -eq 1 ]; then
    UI_ITEMS[$n]="$recommended  $GOES_GLYPH_OK best for your display"
    UI_HINTS[$n]="$(setup::_res_hint "$recommended" "$sizes")"
    UI_GROUPS[$n]="Recommended"
    SETUP_RES_OPT[$n]="$recommended"
    [ "$recommended" = "$CFG_resolution" ] && initial="$n"
    n=$((n + 1))
  fi

  while IFS='	' read -r pixels res; do
    [ -z "$res" ] && continue
    [ "$show_recommended" -eq 1 ] && [ "$res" = "$recommended" ] && continue
    UI_ITEMS[$n]="$res"
    UI_HINTS[$n]="$(setup::_res_hint "$res" "$sizes")"
    UI_GROUPS[$n]="All sizes"
    SETUP_RES_OPT[$n]="$res"
    [ "$res" = "$CFG_resolution" ] && initial="$n"
    n=$((n + 1))
  done <<EOT
$list
EOT

  UI_TITLE="How large should each frame be?"
  UI_SUBTITLE="This downloads once per interval, so mind your bandwidth"
  UI_INITIAL="$initial"
  ui::select || return 1
  SETUP_RESOLUTION="${SETUP_RES_OPT[$UI_RESULT]}"
  goes::ok "Image size: $SETUP_RESOLUTION"
  return 0
}
SETUP_RES_OPT=()

# ── Step 3: framing ──────────────────────────────────────────────────────────
SETUP_SCALING=''

setup::choose_scaling() {
  setup::_step "How should it sit on your screen?"
  UI_ITEMS=(); UI_HINTS=(); UI_GROUPS=()
  SETUP_SCALE_OPT=(fit fill center stretch)
  UI_ITEMS[0]="Fit";     UI_HINTS[0]="whole frame, black around it"
  UI_ITEMS[1]="Fill";    UI_HINTS[1]="covers the screen, crops edges"
  UI_ITEMS[2]="Center";  UI_HINTS[2]="original pixels, no scaling"
  UI_ITEMS[3]="Stretch"; UI_HINTS[3]="distorts to fit exactly"

  local initial=0 i=0
  while [ "$i" -lt 4 ]; do
    [ "${SETUP_SCALE_OPT[$i]}" = "$CFG_scaling" ] && initial="$i"
    i=$((i + 1))
  done

  UI_TITLE="Framing"
  if [ "$SETUP_VIEW" = "fd" ]; then
    UI_SUBTITLE="Full-disk images are square; Fit puts the planet on a black field"
  else
    UI_SUBTITLE="Sector images are 5:3; Fill usually looks best on a widescreen display"
    initial=1
  fi
  UI_INITIAL="$initial"
  ui::select || return 1
  SETUP_SCALING="${SETUP_SCALE_OPT[$UI_RESULT]}"
  goes::ok "Framing: $SETUP_SCALING"
  return 0
}
SETUP_SCALE_OPT=()

# ── Step 4: cadence ──────────────────────────────────────────────────────────
SETUP_INTERVAL=''

setup::_valid_interval() {
  printf '%s' "$1" | grep -qE '^[0-9]{1,4}$' && [ "$1" -ge 1 ] && [ "$1" -le 1440 ]
}

setup::choose_interval() {
  setup::_step "How often should it refresh?"
  UI_ITEMS=(); UI_HINTS=(); UI_GROUPS=()
  SETUP_INT_OPT=(10 5 15 30 60 custom)
  UI_ITEMS[0]="Every 10 minutes"; UI_HINTS[0]="matches NOAA's publish rate"
  UI_ITEMS[1]="Every 5 minutes";  UI_HINTS[1]="some frames will repeat"
  UI_ITEMS[2]="Every 15 minutes"; UI_HINTS[2]=""
  UI_ITEMS[3]="Every 30 minutes"; UI_HINTS[3]="lighter on bandwidth"
  UI_ITEMS[4]="Every hour";       UI_HINTS[4]="lightest"
  UI_ITEMS[5]="Something else";   UI_HINTS[5]="type your own"

  UI_TITLE="Refresh interval"
  UI_SUBTITLE="GOES publishes a new frame roughly every 10 minutes"
  UI_INITIAL=0
  ui::select || return 1

  local choice="${SETUP_INT_OPT[$UI_RESULT]}"
  if [ "$choice" = "custom" ]; then
    choice=$(ui::ask "Minutes between refreshes" "${CFG_interval:-10}" setup::_valid_interval)
  fi
  SETUP_INTERVAL="$choice"
  goes::ok "Refreshing every $SETUP_INTERVAL minutes"
  return 0
}
SETUP_INT_OPT=()

# ── Step 5: power ────────────────────────────────────────────────────────────
SETUP_ON_BATTERY='skip'

setup::_has_battery() {
  if [ "$GOES_PLATFORM" = "macos" ]; then
    pmset -g batt 2>/dev/null | grep -q "InternalBattery"
  else
    ls /sys/class/power_supply/BAT* >/dev/null 2>&1
  fi
}

setup::choose_power() {
  if ! setup::_has_battery; then
    SETUP_ON_BATTERY='run'
    SETUP_TOTAL=4
    return 0
  fi
  setup::_step "On battery"
  UI_ITEMS=(); UI_HINTS=(); UI_GROUPS=()
  SETUP_PWR_OPT=(skip run)
  UI_ITEMS[0]="Pause on battery"; UI_HINTS[0]="saves power and data"
  UI_ITEMS[1]="Keep refreshing";  UI_HINTS[1]="always up to date"
  local initial=0
  [ "$CFG_on_battery" = "run" ] && initial=1
  UI_TITLE="Battery behavior"
  UI_SUBTITLE="Downloads and wallpaper changes both cost a little battery"
  UI_INITIAL="$initial"
  ui::select || return 1
  SETUP_ON_BATTERY="${SETUP_PWR_OPT[$UI_RESULT]}"
  goes::ok "On battery: $SETUP_ON_BATTERY"
  return 0
}
SETUP_PWR_OPT=()

# ── Orchestration ────────────────────────────────────────────────────────────
setup::summary() {
  goes::heading "Summary"
  ui::kv "View" "$SETUP_LABEL"
  ui::kv "Satellite" "$(catalog::sat_label "$SETUP_SAT") ($SETUP_SAT, $(catalog::sat_position "$SETUP_SAT"))"
  ui::kv "Size" "$SETUP_RESOLUTION"
  ui::kv "Framing" "$SETUP_SCALING"
  ui::kv "Refresh" "every $SETUP_INTERVAL min"
  ui::kv "On battery" "$SETUP_ON_BATTERY"
  ui::kv "Config" "$GOES_CONFIG_FILE"
  printf '\n' >&2
}

setup::apply() {
  config::set view "$SETUP_VIEW" || return 1
  config::set satellite "$SETUP_SAT" || return 1
  config::set sector "$SETUP_SECTOR" || return 1
  config::set resolution "$SETUP_RESOLUTION" || return 1
  config::set scaling "$SETUP_SCALING" || return 1
  config::set interval "$SETUP_INTERVAL" || return 1
  config::set on_battery "$SETUP_ON_BATTERY" || return 1
  config::save
}

# setup::run [--no-service]
setup::run() {
  local install_service=1
  [ "${1:-}" = "--no-service" ] && install_service=0

  config::load

  if config::legacy_present && ! config::is_configured; then
    goes::info "Found a configuration from an older version."
    if config::migrate_legacy; then
      goes::ok "Imported: $(config::describe)"
    fi
  fi

  setup::choose_region   || { goes::warn "Setup cancelled."; return 130; }
  setup::choose_resolution || { goes::warn "Setup cancelled."; return 130; }
  setup::choose_scaling  || { goes::warn "Setup cancelled."; return 130; }
  setup::choose_interval || { goes::warn "Setup cancelled."; return 130; }
  setup::choose_power    || { goes::warn "Setup cancelled."; return 130; }

  setup::summary
  if ! ui::confirm "Save this configuration?" y; then
    goes::warn "Nothing was saved."
    return 130
  fi

  setup::apply || return 1
  goes::ok "Saved to $GOES_CONFIG_FILE"
  config::archive_legacy

  if service::legacy_present; then
    goes::info "Cleaning up scheduling left over from the older version."
    service::remove_legacy
  fi

  if [ "$install_service" -eq 1 ]; then
    if ui::confirm "Keep the wallpaper updating in the background?" y; then
      if service::start; then
        goes::ok "Installed: $(service::describe)"
      else
        goes::warn "Background updates are not active; run '$GOES_PROG start' to retry."
      fi
    fi
  fi

  return 0
}
