#!/usr/bin/env bash
# `goes doctor` — checks every link in the chain and says what to do about
# whatever is broken.
#
# Each check reports pass / warn / fail. Failures carry a concrete next step;
# a check that cannot run says so rather than reporting a false pass.

[ -n "${_GOES_DOCTOR_SH:-}" ] && return 0
_GOES_DOCTOR_SH=1

# shellcheck source=lib/setup.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/setup.sh"
# shellcheck source=lib/state.sh
. "${GOES_LIB_DIR}/state.sh"

DOCTOR_PASS=0
DOCTOR_WARN=0
DOCTOR_FAIL=0

doctor::_pass() {
  DOCTOR_PASS=$((DOCTOR_PASS + 1))
  printf '  %s%s%s %s%s\n' "$C_GREEN" "$GOES_GLYPH_OK" "$C_RESET" "$(ui::pad "$1" 26)" "${2:+$C_GREY$2$C_RESET}" >&2
}

doctor::_warn() {
  DOCTOR_WARN=$((DOCTOR_WARN + 1))
  printf '  %s%s%s %s%s\n' "$C_YELLOW" "$GOES_GLYPH_WARN" "$C_RESET" "$(ui::pad "$1" 26)" "${2:+$C_YELLOW$2$C_RESET}" >&2
  [ -n "${3:-}" ] && goes::hint "$3"
  return 0
}

doctor::_fail() {
  DOCTOR_FAIL=$((DOCTOR_FAIL + 1))
  printf '  %s%s%s %s%s\n' "$C_RED" "$GOES_GLYPH_FAIL" "$C_RESET" "$(ui::pad "$1" 26)" "${2:+$C_RED$2$C_RESET}" >&2
  [ -n "${3:-}" ] && goes::hint "$3"
  return 0
}

# ── Checks ───────────────────────────────────────────────────────────────────
doctor::check_environment() {
  goes::heading "Environment"

  if [ "$GOES_PLATFORM" = "unsupported" ]; then
    doctor::_fail "Platform" "${OSTYPE:-unknown}" "Only macOS and Linux are supported."
  else
    doctor::_pass "Platform" "$GOES_PLATFORM"
  fi

  doctor::_pass "Bash" "${BASH_VERSION%%(*}"

  local missing='' cmd
  for cmd in curl date grep sed awk; do
    goes::have "$cmd" || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    doctor::_fail "Required tools" "missing:$missing" "Install them with your package manager."
  else
    doctor::_pass "Required tools" "curl, coreutils"
  fi

  if [ "$GOES_PLATFORM" = "macos" ]; then
    if goes::have swiftc; then
      doctor::_pass "Swift toolchain" "wallpaper helper can be compiled"
    else
      doctor::_warn "Swift toolchain" "not found" \
        "Wallpaper will be set through AppleScript instead. 'xcode-select --install' enables the faster path."
    fi
  fi

  local link found=''
  for link in "$HOME/.local/bin/goes" "/usr/local/bin/goes"; do
    [ -e "$link" ] && found="$link"
  done
  if [ -n "$found" ]; then
    case ":$PATH:" in
      *":$(dirname "$found"):"*) doctor::_pass "On PATH" "$found" ;;
      *) doctor::_warn "On PATH" "$found not on PATH" \
           "Add: export PATH=\"\$PATH:$(dirname "$found")\"" ;;
    esac
  else
    doctor::_warn "On PATH" "no 'goes' symlink found" \
      "Create one: ln -s $GOES_ROOT_DIR/bin/goes \$HOME/.local/bin/goes"
  fi
}

doctor::check_config() {
  goes::heading "Configuration"
  config::load

  if ! config::is_configured; then
    doctor::_fail "Config file" "not configured" "Run: $GOES_PROG setup"
    return 1
  fi
  doctor::_pass "Config file" "$GOES_CONFIG_FILE"
  doctor::_pass "Region" "$(config::describe)"
  doctor::_pass "Interval" "every $CFG_interval min"

  if config::legacy_present; then
    doctor::_warn "Old v1 config" "still present in ${XDG_CONFIG_HOME:-$HOME/.config}" \
      "Harmless. '$GOES_PROG setup' will archive it."
  fi

  local dir w
  for dir in "$GOES_CONFIG_DIR" "$GOES_IMAGE_DIR" "$GOES_STATE_DIR"; do
    if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then w=1; else w=0; fi
    [ "$w" -eq 1 ] || doctor::_fail "Writable" "$dir" "Fix the permissions on $dir."
  done
  [ "$DOCTOR_FAIL" -eq 0 ] && doctor::_pass "Directories" "config, cache and state are writable"
  return 0
}

doctor::check_network() {
  goes::heading "NOAA connectivity"

  if ! net::online; then
    doctor::_fail "CDN reachable" "cdn.star.nesdis.noaa.gov unreachable" \
      "Check your connection, proxy or DNS, then run '$GOES_PROG doctor' again."
    return 1
  fi
  doctor::_pass "CDN reachable" "cdn.star.nesdis.noaa.gov"

  config::is_configured || return 0

  local dir_url list
  dir_url=$(catalog::image_dir_url "$CFG_satellite" "$CFG_view" "$CFG_sector" "$CFG_product")
  if list=$(catalog::resolutions "$dir_url"); then
    doctor::_pass "Region listing" "$(printf '%s\n' "$list" | wc -l | tr -d ' ') sizes available"
  else
    doctor::_fail "Region listing" "$dir_url" \
      "That region may have been retired. Run '$GOES_PROG setup' to choose another."
    return 1
  fi

  local resolution bytes
  resolution=$(fetch::resolve_resolution "$dir_url") || resolution=''
  if [ -n "$resolution" ]; then
    bytes=$(net::content_length "$dir_url/$resolution.jpg" 2>/dev/null)
    doctor::_pass "Selected frame" "$resolution${bytes:+ ($(goes::human_bytes "$bytes"))}"
  else
    doctor::_fail "Selected frame" "could not resolve a size" "Try: $GOES_PROG config set resolution auto"
  fi
  return 0
}

doctor::check_service() {
  goes::heading "Background updates"

  if service::is_running; then
    doctor::_pass "Scheduler" "$(service::describe)"
    local next; next=$(service::next_run)
    [ -n "$next" ] && doctor::_pass "Next run" "$next"
  else
    doctor::_warn "Scheduler" "not running" "Start it with: $GOES_PROG start"
  fi

  if service::legacy_present; then
    doctor::_warn "Old v1 scheduling" "cron or LaunchAgent still installed" \
      "Remove it with: $GOES_PROG start (it cleans up automatically)"
  fi

  state::read
  case "${ST_last_status:-never}" in
    ok)        doctor::_pass "Last run" "$(goes::relative_time "$ST_last_run") via $ST_last_detail" ;;
    unchanged) doctor::_pass "Last run" "$(goes::relative_time "$ST_last_run"), no new frame" ;;
    skipped)   doctor::_warn "Last run" "$(goes::relative_time "$ST_last_run"): $ST_last_detail" ;;
    error)     doctor::_fail "Last run" "$(goes::relative_time "$ST_last_run"): $ST_last_detail" \
                 "See details with: $GOES_PROG log" ;;
    *)         doctor::_warn "Last run" "never" "Try: $GOES_PROG update --force" ;;
  esac
}

doctor::check_display() {
  goes::heading "Display"

  local backend
  if [ "$CFG_trim_caption" != "true" ]; then
    doctor::_pass "Caption strip" "shown (trim_caption=false)"
  elif backend=$(image::describe_backend); then
    doctor::_pass "Caption strip" "removed with $backend"
  else
    doctor::_warn "Caption strip" "cannot be removed: no image tool" \
      "Install ImageMagick (sudo apt install imagemagick), or: $GOES_PROG config set trim_caption false"
  fi

  local screen
  screen=$(wallpaper::screen_size)
  if [ -n "$screen" ]; then
    doctor::_pass "Detected display" "$screen"
  else
    doctor::_warn "Detected display" "unknown" "Resolution recommendations will be skipped."
  fi

  if [ "$GOES_PLATFORM" = "linux" ]; then
    if [ -n "${XDG_CURRENT_DESKTOP:-}" ]; then
      doctor::_pass "Desktop" "$XDG_CURRENT_DESKTOP"
    else
      doctor::_warn "Desktop" "XDG_CURRENT_DESKTOP is unset" \
        "The wallpaper backend will be guessed from running processes."
    fi
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
      doctor::_warn "Session bus" "DBUS_SESSION_BUS_ADDRESS is unset" \
        "It is recovered automatically at update time; this only matters if updates fail."
    else
      doctor::_pass "Session bus" "available"
    fi
  fi

  if wallpaper::on_ac_power; then
    doctor::_pass "Power" "on AC"
  else
    if [ "$CFG_on_battery" = "skip" ]; then
      doctor::_warn "Power" "on battery; updates are paused" \
        "Change it with: $GOES_PROG config set on_battery run"
    else
      doctor::_pass "Power" "on battery; updates continue"
    fi
  fi
}

doctor::live_test() {
  goes::heading "End-to-end test"
  config::is_configured || { doctor::_warn "Live test" "skipped, not configured"; return 0; }

  ui::spin_start "Downloading the latest frame"
  fetch::latest >/dev/null 2>&1
  local status=$?
  if [ "$status" -eq 1 ]; then
    ui::spin_stop 1 "Download failed"
    doctor::_fail "Download" "see $GOES_LOG_FILE" "Run '$GOES_PROG update --force' to see the error."
    return 1
  fi
  ui::spin_stop 0 "Downloaded $(basename "$FETCH_IMAGE") ($(goes::human_bytes "$FETCH_BYTES"))"
  doctor::_pass "Download" "$FETCH_RESOLUTION"

  ui::spin_start "Applying it to your desktop"
  if wallpaper::set "$FETCH_IMAGE" "$CFG_scaling" >/dev/null 2>&1; then
    ui::spin_stop 0 "Wallpaper set via $WALLPAPER_BACKEND"
    doctor::_pass "Wallpaper" "$WALLPAPER_BACKEND"
    state::write ok "$FETCH_IMAGE" "$WALLPAPER_BACKEND" 2>/dev/null || true
  else
    ui::spin_stop 1 "Could not set the wallpaper"
    if [ "$GOES_PLATFORM" = "macos" ]; then
      doctor::_fail "Wallpaper" "all backends failed" \
        "Grant Automation and Desktop permissions to your terminal in System Settings > Privacy & Security."
    else
      doctor::_fail "Wallpaper" "all backends failed" \
        "Install 'feh' for a universal X11 fallback, or report your desktop at $GOES_REPO_WEB"
    fi
    return 1
  fi
  return 0
}

# ── Entry point ──────────────────────────────────────────────────────────────
doctor::run() {
  local live=1 arg
  for arg in "$@"; do
    case "$arg" in
      --no-test) live=0 ;;
      *) goes::die "doctor: unknown option '$arg'" ;;
    esac
  done

  ui::banner "checking your installation"

  doctor::check_environment
  doctor::check_config
  doctor::check_network
  doctor::check_service
  doctor::check_display
  [ "$live" -eq 1 ] && doctor::live_test

  printf '\n' >&2
  goes::rule
  printf '  %s%s passed%s   %s%s warnings%s   %s%s failures%s\n' \
    "$C_GREEN" "$DOCTOR_PASS" "$C_RESET" \
    "$C_YELLOW" "$DOCTOR_WARN" "$C_RESET" \
    "$C_RED" "$DOCTOR_FAIL" "$C_RESET" >&2
  goes::rule
  printf '\n' >&2

  if [ "$DOCTOR_FAIL" -gt 0 ]; then
    goes::err "Something is broken. The hints above say what to do."
    return 1
  fi
  if [ "$DOCTOR_WARN" -gt 0 ]; then
    goes::warn "Working, with notes."
    return 0
  fi
  goes::ok "Everything checks out."
  return 0
}
