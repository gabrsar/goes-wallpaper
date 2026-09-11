#!/usr/bin/env bash
# Background scheduling: a launchd agent on macOS, a systemd user timer on
# Linux. Both are per-user and need no root.
#
# Unit files are generated rather than templated so that paths are escaped
# correctly for their format (XML for launchd, plain text for systemd).

[ -n "${_GOES_SERVICE_SH:-}" ] && return 0
_GOES_SERVICE_SH=1

# shellcheck source=lib/common.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/common.sh"
# shellcheck source=lib/config.sh
. "${GOES_LIB_DIR}/config.sh"

GOES_LAUNCHD_LABEL="com.github.gabrsar.goes-wallpaper"
GOES_LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$GOES_LAUNCHD_LABEL.plist"
GOES_SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
GOES_SYSTEMD_SERVICE="$GOES_SYSTEMD_DIR/goes-wallpaper.service"
GOES_SYSTEMD_TIMER="$GOES_SYSTEMD_DIR/goes-wallpaper.timer"

service::_bin() {
  printf '%s/bin/goes' "$GOES_ROOT_DIR"
}

service::_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# ── macOS (launchd) ──────────────────────────────────────────────────────────
service::_write_plist() {
  local bin interval
  bin=$(service::_xml_escape "$(service::_bin)")
  interval=$(( ${CFG_interval:-10} * 60 ))

  mkdir -p "$(dirname "$GOES_LAUNCHD_PLIST")" || return 1
  cat >"$GOES_LAUNCHD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$GOES_LAUNCHD_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$bin</string>
		<string>update</string>
	</array>
	<key>StartInterval</key>
	<integer>$interval</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$(service::_xml_escape "$GOES_STATE_DIR/launchd.out.log")</string>
	<key>StandardErrorPath</key>
	<string>$(service::_xml_escape "$GOES_STATE_DIR/launchd.err.log")</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
	</dict>
</dict>
</plist>
PLIST
}

service::_launchd_loaded() {
  launchctl print "gui/$(id -u)/$GOES_LAUNCHD_LABEL" >/dev/null 2>&1
}

service::_start_macos() {
  mkdir -p "$GOES_STATE_DIR"
  service::_write_plist || { goes::err "could not write $GOES_LAUNCHD_PLIST"; return 1; }

  service::_launchd_loaded && launchctl bootout "gui/$(id -u)/$GOES_LAUNCHD_LABEL" 2>/dev/null
  if ! launchctl bootstrap "gui/$(id -u)" "$GOES_LAUNCHD_PLIST" 2>/dev/null; then
    # Older macOS releases only speak the legacy verbs.
    launchctl load -w "$GOES_LAUNCHD_PLIST" 2>/dev/null \
      || { goes::err "launchctl refused to load $GOES_LAUNCHD_PLIST"; return 1; }
  fi
  launchctl enable "gui/$(id -u)/$GOES_LAUNCHD_LABEL" 2>/dev/null || true
  goes::log info "event=service_started platform=macos interval=${CFG_interval}m"
  return 0
}

service::_stop_macos() {
  local stopped=1
  if service::_launchd_loaded; then
    launchctl bootout "gui/$(id -u)/$GOES_LAUNCHD_LABEL" 2>/dev/null && stopped=0
  fi
  [ -f "$GOES_LAUNCHD_PLIST" ] && { launchctl unload "$GOES_LAUNCHD_PLIST" 2>/dev/null; rm -f "$GOES_LAUNCHD_PLIST"; stopped=0; }
  goes::log info "event=service_stopped platform=macos"
  return $stopped
}

service::_status_macos() {
  service::_launchd_loaded
}

# ── Linux (systemd user timer) ───────────────────────────────────────────────
service::_write_units() {
  local bin; bin=$(service::_bin)
  mkdir -p "$GOES_SYSTEMD_DIR" || return 1

  cat >"$GOES_SYSTEMD_SERVICE" <<UNIT
[Unit]
Description=Set the desktop wallpaper from live GOES satellite imagery
Documentation=$GOES_REPO_WEB
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=$bin update
Nice=10
IOSchedulingClass=idle
UNIT

  cat >"$GOES_SYSTEMD_TIMER" <<UNIT
[Unit]
Description=Refresh the GOES satellite wallpaper every ${CFG_interval:-10} minutes
Documentation=$GOES_REPO_WEB

[Timer]
OnStartupSec=30s
OnUnitActiveSec=${CFG_interval:-10}min
AccuracySec=30s
Persistent=true
Unit=goes-wallpaper.service

[Install]
WantedBy=timers.target
UNIT
}

service::_start_linux() {
  goes::have systemctl || {
    goes::err "systemd is required for background updates on Linux."
    goes::hint "Without it, add '$(service::_bin) update' to your desktop's own scheduler."
    return 1
  }
  service::_write_units || { goes::err "could not write systemd units to $GOES_SYSTEMD_DIR"; return 1; }

  # The timer runs outside the graphical session; hand it the session's
  # display and bus variables so wallpaper backends can reach the compositor.
  systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY \
    DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR 2>/dev/null || true

  systemctl --user daemon-reload || return 1
  systemctl --user enable --now goes-wallpaper.timer || {
    goes::err "systemctl could not enable goes-wallpaper.timer"
    return 1
  }
  goes::log info "event=service_started platform=linux interval=${CFG_interval}m"
  return 0
}

service::_stop_linux() {
  goes::have systemctl || return 1
  systemctl --user disable --now goes-wallpaper.timer 2>/dev/null
  systemctl --user daemon-reload 2>/dev/null
  goes::log info "event=service_stopped platform=linux"
  return 0
}

service::_status_linux() {
  goes::have systemctl || return 1
  systemctl --user is-active goes-wallpaper.timer >/dev/null 2>&1
}

# ── Public API ───────────────────────────────────────────────────────────────
service::start() {
  case "$GOES_PLATFORM" in
    macos) service::_start_macos ;;
    linux) service::_start_linux ;;
    *) goes::err "unsupported platform"; return 1 ;;
  esac
}

service::stop() {
  case "$GOES_PLATFORM" in
    macos) service::_stop_macos ;;
    linux) service::_stop_linux ;;
    *) return 1 ;;
  esac
}

service::restart() {
  service::stop >/dev/null 2>&1
  service::start
}

service::is_running() {
  case "$GOES_PLATFORM" in
    macos) service::_status_macos ;;
    linux) service::_status_linux ;;
    *) return 1 ;;
  esac
}

service::next_run() {
  if [ "$GOES_PLATFORM" = "linux" ] && goes::have systemctl; then
    systemctl --user list-timers goes-wallpaper.timer --no-pager --no-legend 2>/dev/null \
      | awk '{print $1, $2, $3}'
  fi
}

service::describe() {
  case "$GOES_PLATFORM" in
    macos) printf 'launchd agent %s' "$GOES_LAUNCHD_LABEL" ;;
    linux) printf 'systemd user timer goes-wallpaper.timer' ;;
    *)     printf 'none' ;;
  esac
}

# ── Legacy (pre-2.0) scheduling cleanup ──────────────────────────────────────
GOES_LEGACY_CRON_MARKER="# goes-wallpaper"
GOES_LEGACY_PLIST="$HOME/Library/LaunchAgents/com.goes-wallpaper.plist"
GOES_LEGACY_SYSTEMD="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/goes.service"

service::legacy_present() {
  [ "$GOES_PLATFORM" = "macos" ] && [ -f "$GOES_LEGACY_PLIST" ] && return 0
  [ "$GOES_PLATFORM" = "linux" ] && [ -f "$GOES_LEGACY_SYSTEMD" ] && return 0
  crontab -l 2>/dev/null | grep -q "$GOES_LEGACY_CRON_MARKER" && return 0
  return 1
}

service::remove_legacy() {
  local removed=0

  local current kept
  current=$(crontab -l 2>/dev/null) || current=''
  if printf '%s\n' "$current" | grep -q "$GOES_LEGACY_CRON_MARKER"; then
    # Read fully before writing: never stream `crontab -l` into `crontab -`.
    # grep -v exits 1 when ours was the only entry, which is still success.
    kept=$(printf '%s\n' "$current" | grep -v "$GOES_LEGACY_CRON_MARKER") || kept=''
    if printf '%s' "${kept:+$kept
}" | crontab -; then
      goes::info "Removed the old cron entry."
      removed=1
    else
      goes::warn "Could not edit your crontab; remove the '# goes-wallpaper' line with: crontab -e"
    fi
  fi

  if [ "$GOES_PLATFORM" = "macos" ] && [ -f "$GOES_LEGACY_PLIST" ]; then
    launchctl bootout "gui/$(id -u)" "$GOES_LEGACY_PLIST" 2>/dev/null
    launchctl unload "$GOES_LEGACY_PLIST" 2>/dev/null
    rm -f "$GOES_LEGACY_PLIST" && { goes::info "Removed the old LaunchAgent."; removed=1; }
  fi

  if [ "$GOES_PLATFORM" = "linux" ] && [ -f "$GOES_LEGACY_SYSTEMD" ]; then
    systemctl --user disable --now goes.service 2>/dev/null
    rm -f "$GOES_LEGACY_SYSTEMD"
    systemctl --user daemon-reload 2>/dev/null
    goes::info "Removed the old systemd service."
    removed=1
  fi

  [ "$removed" -eq 1 ] && goes::log info "event=legacy_scheduling_removed"
  return 0
}
