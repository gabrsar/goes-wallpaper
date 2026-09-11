#!/usr/bin/env bash
# Setting the desktop background, across macOS and the Linux desktops.
#
# Every backend reports success or failure honestly: if no backend applies the
# image the caller gets a non-zero status and an actionable message, rather
# than a silent no-op.

[ -n "${_GOES_WALLPAPER_SH:-}" ] && return 0
_GOES_WALLPAPER_SH=1

# shellcheck source=lib/common.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/common.sh"

WALLPAPER_BACKEND=''

# ── macOS ────────────────────────────────────────────────────────────────────
# NSWorkspace is the only API that reliably covers every space and display on
# modern macOS. The helper is compiled once and cached; `swift` as a script
# interpreter costs ~2s per run, which is far too slow for a 10-minute timer.
GOES_SWIFT_SOURCE_NAME='set-wallpaper.swift'

wallpaper::_mac_helper_path() { printf '%s/bin/goes-set-wallpaper' "$GOES_CACHE_DIR"; }

wallpaper::_mac_build_helper() {
  local src="$GOES_SHARE_DIR/$GOES_SWIFT_SOURCE_NAME"
  local out; out=$(wallpaper::_mac_helper_path)
  [ -f "$src" ] || return 1
  goes::have swiftc || return 1

  # Rebuild only when the source is newer than the cached binary.
  if [ -x "$out" ] && [ "$(goes::mtime "$out")" -ge "$(goes::mtime "$src")" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$out")" || return 1
  if swiftc -O -o "$out.tmp" "$src" >/dev/null 2>&1 && mv -f "$out.tmp" "$out"; then
    goes::log info "event=swift_helper_built path=$out"
    return 0
  fi
  rm -f "$out.tmp"
  return 1
}

wallpaper::_set_macos() {
  local image="$1" mode="$2" out status helper
  helper=$(wallpaper::_mac_helper_path)

  if wallpaper::_mac_build_helper && [ -x "$helper" ]; then
    out=$("$helper" "$image" "$mode" 2>&1); status=$?
    if [ "$status" -eq 0 ]; then
      WALLPAPER_BACKEND='nsworkspace'
      return 0
    fi
    goes::log warn "event=wallpaper_backend_failed backend=nsworkspace status=$status detail=${out//$'\n'/ }"
  fi

  # No Swift toolchain (or it failed): AppleScript still works, though it only
  # covers the current space on some macOS releases.
  if out=$(osascript -e "tell application \"System Events\" to tell every desktop to set picture to POSIX file \"$image\"" 2>&1); then
    WALLPAPER_BACKEND='system-events'
    return 0
  fi
  goes::log warn "event=wallpaper_backend_failed backend=system-events detail=${out//$'\n'/ }"

  if out=$(osascript -e "tell application \"Finder\" to set desktop picture to POSIX file \"$image\"" 2>&1); then
    WALLPAPER_BACKEND='finder'
    return 0
  fi
  goes::log error "event=wallpaper_all_backends_failed platform=macos detail=${out//$'\n'/ }"
  goes::err "Could not set the wallpaper."
  goes::hint "Grant your terminal (or /usr/bin/osascript) Automation + Desktop access in"
  goes::hint "System Settings > Privacy & Security, then run: $GOES_PROG update --force"
  return 1
}

# ── Linux ────────────────────────────────────────────────────────────────────
# A user systemd unit starts without the graphical session's environment.
# Recover DISPLAY / WAYLAND_DISPLAY / DBUS_SESSION_BUS_ADDRESS from a process
# that does have them, otherwise gsettings and friends silently target nothing.
wallpaper::_recover_session_env() {
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && return 0

  local uid pid environ
  uid=$(id -u)
  [ -d /proc ] || return 1

  for pid in $(pgrep -u "$uid" -x 'gnome-session|plasmashell|xfce4-session|cinnamon-session|mate-session|sway|Hyprland|lxqt-session|i3|openbox' 2>/dev/null); do
    environ="/proc/$pid/environ"
    [ -r "$environ" ] || continue
    local line key value
    while IFS= read -r -d '' line; do
      key="${line%%=*}"; value="${line#*=}"
      case "$key" in
        DISPLAY|WAYLAND_DISPLAY|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY|XDG_RUNTIME_DIR|XDG_CURRENT_DESKTOP)
          [ -n "$value" ] && export "$key=$value" ;;
      esac
    done <"$environ"
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && return 0
  done

  [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$uid/bus" ] \
    && export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus"
  return 0
}

wallpaper::_desktop_id() {
  local d="${XDG_CURRENT_DESKTOP:-}${XDG_SESSION_DESKTOP:+:$XDG_SESSION_DESKTOP}"
  printf '%s' "$d" | tr '[:upper:]' '[:lower:]'
}

wallpaper::_running() { pgrep -x "$1" >/dev/null 2>&1; }

# Translate our scaling vocabulary into the freedesktop picture-options values.
wallpaper::_gnome_picture_option() {
  case "$1" in
    fill)    printf 'zoom' ;;
    stretch) printf 'stretched' ;;
    center)  printf 'centered' ;;
    *)       printf 'scaled' ;;
  esac
}

wallpaper::_try_gnome() {
  local image="$1" schema="$2" mode="${3:-fit}"
  goes::have gsettings || return 1
  gsettings writable "$schema" picture-uri >/dev/null 2>&1 || return 1
  gsettings set "$schema" picture-uri "file://$image" 2>/dev/null || return 1
  # Present since GNOME 42; absent on older releases, which is not an error.
  gsettings set "$schema" picture-uri-dark "file://$image" 2>/dev/null || true
  gsettings set "$schema" picture-options "$(wallpaper::_gnome_picture_option "$mode")" 2>/dev/null || true
  return 0
}

wallpaper::_try_kde() {
  local image="$1"
  if goes::have plasma-apply-wallpaperimage; then
    plasma-apply-wallpaperimage "$image" >/dev/null 2>&1 && return 0
  fi
  goes::have qdbus || return 1
  qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
    var ds = desktops();
    for (var i = 0; i < ds.length; i++) {
      ds[i].wallpaperPlugin = 'org.kde.image';
      ds[i].currentConfigGroup = Array('Wallpaper', 'org.kde.image', 'General');
      ds[i].writeConfig('Image', 'file://$image');
    }" >/dev/null 2>&1
}

wallpaper::_try_xfce() {
  local image="$1" prop applied=0
  goes::have xfconf-query || return 1
  # Apply to every monitor/workspace backdrop, not just the first one.
  for prop in $(xfconf-query -c xfce4-desktop -l 2>/dev/null | grep -E 'last-image$'); do
    xfconf-query -c xfce4-desktop -p "$prop" -s "$image" 2>/dev/null && applied=1
  done
  [ "$applied" -eq 1 ]
}

wallpaper::_try_wayland_bg() {
  local image="$1" mode="${2:-fit}" wl_mode
  case "$mode" in
    fill)    wl_mode='fill' ;;
    stretch) wl_mode='stretch' ;;
    center)  wl_mode='center' ;;
    *)       wl_mode='fit' ;;
  esac
  if goes::have swaymsg && [ -n "${SWAYSOCK:-}" ]; then
    swaymsg output '*' bg "$image" "$wl_mode" >/dev/null 2>&1 && return 0
  fi
  if goes::have hyprctl && wallpaper::_running Hyprland; then
    hyprctl hyprpaper reload ",$image" >/dev/null 2>&1 && return 0
  fi
  if goes::have swaybg; then
    pkill -x swaybg 2>/dev/null
    swaybg -m "$wl_mode" -i "$image" >/dev/null 2>&1 &
    return 0
  fi
  return 1
}

wallpaper::_try_feh() {
  local image="$1" mode="${2:-fit}" flag
  goes::have feh || return 1
  case "$mode" in
    fill)    flag='--bg-fill' ;;
    stretch) flag='--bg-scale' ;;
    center)  flag='--bg-center' ;;
    *)       flag='--bg-max' ;;
  esac
  feh --no-fehbg "$flag" "$image" >/dev/null 2>&1
}

wallpaper::_set_linux() {
  local image="$1" mode="$2" desktop
  wallpaper::_recover_session_env
  desktop=$(wallpaper::_desktop_id)

  # Ordered by specificity: identify the desktop, then fall through to the
  # generic X11/Wayland setters.
  case "$desktop" in
    *gnome*|*unity*|*pop*|*ubuntu*)
      wallpaper::_try_gnome "$image" org.gnome.desktop.background "$mode" \
        && { gsettings set org.gnome.desktop.screensaver picture-uri "file://$image" 2>/dev/null || true
             WALLPAPER_BACKEND='gnome'; return 0; } ;;
    *kde*|*plasma*)
      wallpaper::_try_kde "$image" && { WALLPAPER_BACKEND='kde'; return 0; } ;;
    *xfce*)
      wallpaper::_try_xfce "$image" && { WALLPAPER_BACKEND='xfce'; return 0; } ;;
    *cinnamon*)
      wallpaper::_try_gnome "$image" org.cinnamon.desktop.background "$mode" \
        && { WALLPAPER_BACKEND='cinnamon'; return 0; } ;;
    *mate*)
      if goes::have gsettings && gsettings set org.mate.background picture-filename "$image" 2>/dev/null; then
        WALLPAPER_BACKEND='mate'; return 0
      fi ;;
    *deepin*)
      if goes::have gsettings && gsettings set com.deepin.wrap.gnome.desktop.background picture-uri "file://$image" 2>/dev/null; then
        WALLPAPER_BACKEND='deepin'; return 0
      fi ;;
    *lxqt*)
      if goes::have pcmanfm-qt; then
        pcmanfm-qt --set-wallpaper="$image" >/dev/null 2>&1 && { WALLPAPER_BACKEND='lxqt'; return 0; }
      fi ;;
    *lxde*)
      if goes::have pcmanfm; then
        pcmanfm --set-wallpaper="$image" >/dev/null 2>&1 && { WALLPAPER_BACKEND='lxde'; return 0; }
      fi ;;
  esac

  # Unidentified desktop: probe by running process, then generic setters.
  if wallpaper::_running gnome-shell && wallpaper::_try_gnome "$image" org.gnome.desktop.background "$mode"; then
    WALLPAPER_BACKEND='gnome'; return 0
  fi
  if wallpaper::_running plasmashell && wallpaper::_try_kde "$image"; then
    WALLPAPER_BACKEND='kde'; return 0
  fi
  if wallpaper::_running xfdesktop && wallpaper::_try_xfce "$image"; then
    WALLPAPER_BACKEND='xfce'; return 0
  fi
  if [ -n "${WAYLAND_DISPLAY:-}" ] && wallpaper::_try_wayland_bg "$image" "$mode"; then
    WALLPAPER_BACKEND='wayland'; return 0
  fi
  if wallpaper::_try_feh "$image" "$mode"; then
    WALLPAPER_BACKEND='feh'; return 0
  fi

  goes::log error "event=wallpaper_all_backends_failed platform=linux desktop=$desktop"
  goes::err "Could not set the wallpaper on this desktop (XDG_CURRENT_DESKTOP='${XDG_CURRENT_DESKTOP:-unset}')."
  goes::hint "Install 'feh' for a universal X11 fallback, or open an issue at $GOES_REPO_WEB"
  return 1
}

# ── Public entry point ───────────────────────────────────────────────────────
# wallpaper::set IMAGE [SCALING]
wallpaper::set() {
  local image="$1" mode="${2:-fit}"
  [ -f "$image" ] || { goes::err "image not found: $image"; return 1; }

  # For desktops without a built-in backend: GOES_WALLPAPER_CMD is run with
  # the image path as its last argument.
  if [ -n "${GOES_WALLPAPER_CMD:-}" ]; then
    local out
    # shellcheck disable=SC2086 # word splitting is how the command gets its arguments
    if out=$($GOES_WALLPAPER_CMD "$image" 2>&1); then
      WALLPAPER_BACKEND='custom'
      return 0
    fi
    goes::log error "event=wallpaper_backend_failed backend=custom cmd=$GOES_WALLPAPER_CMD detail=${out//$'\n'/ }"
    goes::err "GOES_WALLPAPER_CMD failed: $GOES_WALLPAPER_CMD"
    return 1
  fi

  case "$GOES_PLATFORM" in
    macos) wallpaper::_set_macos "$image" "$mode" ;;
    linux) wallpaper::_set_linux "$image" "$mode" ;;
    *)     goes::err "unsupported platform: ${OSTYPE:-unknown}"; return 1 ;;
  esac
}

# ── Display geometry (used to recommend a resolution) ────────────────────────
# Prints `WIDTHxHEIGHT` of the largest attached display, or nothing.
wallpaper::screen_size() {
  local out=''
  if [ "$GOES_PLATFORM" = "macos" ]; then
    out=$(system_profiler SPDisplaysDataType 2>/dev/null \
      | grep -oE 'Resolution: [0-9]+ x [0-9]+' \
      | sed -E 's/Resolution: ([0-9]+) x ([0-9]+)/\1x\2/' \
      | LC_ALL=C sort -t x -k1,1n | tail -1)
  else
    if goes::have xrandr && [ -n "${DISPLAY:-}" ]; then
      out=$(xrandr --current 2>/dev/null | grep -oE '[0-9]{3,5}x[0-9]{3,5}\+' \
        | tr -d '+' | LC_ALL=C sort -t x -k1,1n | tail -1)
    fi
    if [ -z "$out" ] && goes::have xdpyinfo; then
      out=$(xdpyinfo 2>/dev/null | grep -oE 'dimensions:[[:space:]]+[0-9]+x[0-9]+' \
        | grep -oE '[0-9]+x[0-9]+' | head -1)
    fi
    if [ -z "$out" ] && goes::have wlr-randr; then
      out=$(wlr-randr 2>/dev/null | grep -oE '[0-9]{3,5}x[0-9]{3,5}' \
        | LC_ALL=C sort -t x -k1,1n | tail -1)
    fi
  fi
  printf '%s' "$out"
}

# Whether the machine is running on wall power. Returns 0 when on AC or when
# power state cannot be determined (a desktop should never be skipped).
wallpaper::on_ac_power() {
  if [ "$GOES_PLATFORM" = "macos" ]; then
    goes::have pmset || return 0
    pmset -g batt 2>/dev/null | grep -q "AC Power" && return 0
    pmset -g batt 2>/dev/null | grep -q "Battery Power" && return 1
    return 0
  fi

  local supply status
  for supply in /sys/class/power_supply/A[CD]*/online /sys/class/power_supply/*/online; do
    [ -r "$supply" ] || continue
    read -r status <"$supply" 2>/dev/null || continue
    [ "$status" = "1" ] && return 0
  done
  # No AC entry at all means no battery subsystem: treat as plugged in.
  ls /sys/class/power_supply/BAT* >/dev/null 2>&1 || return 0
  return 1
}
