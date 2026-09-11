#!/usr/bin/env bash
# Service unit generation. The units are written to a sandbox and inspected;
# nothing is loaded into the real launchd or systemd.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox

# Point the unit paths at the sandbox before sourcing, so the real agent files
# are never touched.
export HOME="$T_SANDBOX/home"
mkdir -p "$HOME/Library/LaunchAgents" "$T_SANDBOX/shims"
# A fake crontab keeps the developer's real one out of the legacy checks.
# Reads with -l, and writes stdin back when given '-'.
printf '#!/bin/sh\nif [ "$1" = "-l" ]; then cat "%s/crontab" 2>/dev/null; elif [ "$1" = "-" ]; then cat >"%s/crontab"; fi\nexit 0\n' "$T_SANDBOX" "$T_SANDBOX" >"$T_SANDBOX/shims/crontab"
chmod +x "$T_SANDBOX/shims/crontab"
export PATH="$T_SANDBOX/shims:$PATH"
. "$GOES_LIB_DIR/service.sh"

config::load
config::set interval 15

t::case "the scheduler is described for this platform"
desc=$(service::describe)
case "$GOES_PLATFORM" in
  macos) assert_contains "$desc" "launchd" "macOS uses launchd" ;;
  linux) assert_contains "$desc" "systemd" "Linux uses a systemd timer" ;;
esac

t::case "the service invokes the installed entry point"
assert_eq "$GOES_ROOT_DIR/bin/goes" "$(service::_bin)" "the absolute path to bin/goes is used"

t::case "XML escaping"
assert_eq 'a&amp;b'  "$(service::_xml_escape 'a&b')"  "ampersands are escaped"
assert_eq '&lt;x&gt;' "$(service::_xml_escape '<x>')" "angle brackets are escaped"
assert_eq '/Users/a b/c' "$(service::_xml_escape '/Users/a b/c')" "spaces are left alone"

t::case "launchd plist generation"
service::_write_plist
assert_file "$GOES_LAUNCHD_PLIST" "the plist is written"
plist=$(cat "$GOES_LAUNCHD_PLIST")
assert_contains "$plist" "<key>Label</key>" "the plist has a label"
assert_contains "$plist" "com.github.gabrsar.goes-wallpaper" "the label is reverse-DNS"
assert_contains "$plist" "<integer>900</integer>" "15 minutes becomes 900 seconds"
assert_contains "$plist" "$GOES_ROOT_DIR/bin/goes" "it runs the installed binary"
assert_contains "$plist" "<string>update</string>" "it runs the update subcommand"
assert_contains "$plist" "<key>RunAtLoad</key>" "it runs once at load"
assert_not_contains "$plist" "sudo" "nothing needs root"

t::case "the plist is valid XML"
if command -v plutil >/dev/null 2>&1; then
  assert_ok "plutil accepts the plist" plutil -lint "$GOES_LAUNCHD_PLIST"
elif command -v xmllint >/dev/null 2>&1; then
  assert_ok "xmllint accepts the plist" xmllint --noout "$GOES_LAUNCHD_PLIST"
else
  t::_pass "skipped: no plist or XML validator available"
fi

t::case "the interval is taken from the configuration"
config::set interval 60
service::_write_plist
assert_contains "$(cat "$GOES_LAUNCHD_PLIST")" "<integer>3600</integer>" "an hour becomes 3600 seconds"

t::case "systemd unit generation"
export XDG_CONFIG_HOME="$T_SANDBOX/xdg"
GOES_SYSTEMD_DIR="$XDG_CONFIG_HOME/systemd/user"
GOES_SYSTEMD_SERVICE="$GOES_SYSTEMD_DIR/goes-wallpaper.service"
GOES_SYSTEMD_TIMER="$GOES_SYSTEMD_DIR/goes-wallpaper.timer"
config::set interval 20
service::_write_units
assert_file "$GOES_SYSTEMD_SERVICE" "the service unit is written"
assert_file "$GOES_SYSTEMD_TIMER" "the timer unit is written"

unit=$(cat "$GOES_SYSTEMD_SERVICE")
assert_contains "$unit" "Type=oneshot" "the service is a one-shot"
assert_contains "$unit" "ExecStart=$GOES_ROOT_DIR/bin/goes update" "it runs a single update"
assert_not_contains "$unit" "User=" "no user is hard-coded into a user unit"

timer=$(cat "$GOES_SYSTEMD_TIMER")
assert_contains "$timer" "OnUnitActiveSec=20min" "the configured interval is used"
assert_contains "$timer" "Persistent=true" "missed runs are caught up after a suspend"
assert_contains "$timer" "WantedBy=timers.target" "the timer can be enabled"

t::case "legacy scheduling is recognized"
assert_status 1 "a clean sandbox has no legacy scheduling" service::legacy_present
touch "$HOME/Library/LaunchAgents/com.goes-wallpaper.plist"
assert_ok "an old LaunchAgent is detected" service::legacy_present
rm -f "$HOME/Library/LaunchAgents/com.goes-wallpaper.plist"
printf '*/5 * * * * /old/goes-update # goes-wallpaper\n' >"$T_SANDBOX/crontab"
assert_ok "an old cron entry is detected" service::legacy_present

t::case "removing a crontab whose only entry is ours"
out=$(service::remove_legacy 2>&1)
assert_contains "$out" "Removed the old cron entry" "success is reported even when nothing else remains"
assert_eq '' "$(cat "$T_SANDBOX/crontab")" "the crontab is left empty"

t::case "other cron entries survive the cleanup"
printf '0 3 * * * /usr/bin/backup\n*/5 * * * * /old/goes-update # goes-wallpaper\n' >"$T_SANDBOX/crontab"
service::remove_legacy >/dev/null 2>&1
assert_eq '0 3 * * * /usr/bin/backup' "$(cat "$T_SANDBOX/crontab")" "unrelated jobs are untouched"

t::summary
