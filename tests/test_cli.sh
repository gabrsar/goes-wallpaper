#!/usr/bin/env bash
# The `goes` command as a user meets it: exit codes, output and side effects.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox

GOES="$GOES_ROOT_DIR/bin/goes"

run() { "$BASH" "$GOES" "$@" 2>&1; }

t::case "the entry point is runnable"
assert_file "$GOES" "bin/goes exists"
[ -x "$GOES" ] && t::_pass "bin/goes is executable" || t::_fail "bin/goes is executable"

t::case "version"
out=$(run version)
assert_contains "$out" "goes-wallpaper 2." "version is printed"
assert_contains "$out" "$GOES_ROOT_DIR" "the install location is printed"
assert_ok "version exits cleanly" "$BASH" "$GOES" version

t::case "help"
out=$(run help)
assert_contains "$out" "goes setup" "help lists setup"
assert_contains "$out" "goes doctor" "help lists doctor"
assert_contains "$out" "goes uninstall" "help lists uninstall"
assert_ok "help exits cleanly" "$BASH" "$GOES" help

t::case "an unknown command is a usage error"
assert_status 64 "exit code 64 for an unknown command" "$BASH" "$GOES" wibble
assert_contains "$(run wibble)" "Unknown command" "the error names the problem"

t::case "status before configuration"
assert_status 1 "status fails when unconfigured" "$BASH" "$GOES" status
assert_contains "$(run status)" "goes setup" "it points at the setup command"

t::case "update before configuration"
assert_status 1 "update fails when unconfigured" "$BASH" "$GOES" update
assert_contains "$(run update)" "Not configured" "the reason is stated"

t::case "a failed update is not recorded as a run"
assert_no_file "$GOES_STATE_HOME/last-run" "no run state after an unconfigured update"

t::case "config set and get"
assert_ok "setting the view" "$BASH" "$GOES" config set view sector
assert_ok "setting the satellite" "$BASH" "$GOES" config set satellite G19
assert_ok "setting the sector" "$BASH" "$GOES" config set sector ssa
assert_eq 'G19' "$(run config get satellite)" "get returns what set stored"
assert_eq 'ssa' "$(run config get sector)" "sector round trips through the CLI"

t::case "config list"
out=$(run config list)
assert_contains "$out" "satellite=G19" "list shows the satellite"
assert_contains "$out" "scaling=fit" "list shows defaults for untouched keys"
lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
assert_eq '10' "$lines" "every setting is listed"

t::case "config rejects bad input"
assert_status 1 "an out-of-range interval is refused" "$BASH" "$GOES" config set interval 0
assert_status 1 "an unknown key is refused" "$BASH" "$GOES" config set colour blue
assert_eq '10' "$(run config get interval)" "the stored value is untouched after a refusal"

t::case "an unknown sector is flagged but accepted"
out=$(run config set sector zz)
assert_contains "$out" "no known sector" "the user is warned"
assert_eq 'zz' "$(run config get sector)" "the value is still stored"
run config set sector ssa >/dev/null

t::case "a known sector is accepted quietly"
assert_not_contains "$(run config set sector ssa)" "no known sector" "no warning for a real region"

t::case "config path"
assert_eq "$GOES_CONFIG_HOME/config" "$(run config path)" "path prints the config location"

t::case "config get needs a key"
assert_status 1 "get with no key fails" "$BASH" "$GOES" config get
assert_status 1 "set with no value fails" "$BASH" "$GOES" config set interval

t::case "status once configured"
out=$(run status)
assert_contains "$out" "South America" "the region is named, not just coded"
assert_contains "$out" "GOES-East" "the satellite is named"
assert_contains "$out" "every 10 min" "the interval is shown"
assert_contains "$out" "never" "a fresh install reports no updates yet"
assert_ok "status succeeds once configured" "$BASH" "$GOES" status

t::case "status works offline"
out=$(GOES_SITE_BASE="https://127.0.0.1:9" GOES_CDN_BASE="https://127.0.0.1:9" run status)
assert_contains "$out" "South America" "the built-in catalog names the region"

t::case "log with no history"
assert_contains "$(run log)" "No log yet" "an absent log is reported plainly"

t::case "update rejects unknown options"
assert_status 1 "a bad flag is refused" "$BASH" "$GOES" update --wat

t::case "open with nothing downloaded"
assert_status 1 "open fails when there is no image" "$BASH" "$GOES" open
assert_contains "$(run open)" "update --force" "it says how to get one"

t::case "command aliases"
assert_ok "'configure' is accepted for setup" "$BASH" -c \
  "GOES_NONINTERACTIVE=1 '$BASH' '$GOES' help >/dev/null"
assert_contains "$(run logs)" "No log yet" "'logs' aliases 'log'"

t::case "a v1 configuration is imported on first use"
V1="$T_SANDBOX/v1"
mkdir -p "$V1/xdg"
printf 'G19\n'       >"$V1/xdg/goes-sat"
printf 'ssa\n'       >"$V1/xdg/goes-sector"
printf '30\n'        >"$V1/xdg/goes-interval"
printf 'false\n'     >"$V1/xdg/goes-keep-images"
printf '7200x4320\n' >"$V1/xdg/goes-resolution"
v1_run() {
  GOES_CONFIG_HOME="$V1/config" GOES_CACHE_HOME="$V1/cache" GOES_STATE_HOME="$V1/state" \
  XDG_CONFIG_HOME="$V1/xdg" GOES_CDN_BASE="https://127.0.0.1:9" GOES_CONNECT_TIMEOUT=1 GOES_RETRIES=1 \
    "$BASH" "$GOES" "$@" 2>&1
}
out=$(v1_run update)
assert_contains "$out" "Imported configuration" "update announces the import"
assert_contains "$out" "Download failed" "then proceeds to download (unreachable here)"
assert_file "$V1/config/config" "the imported config is saved"
assert_eq 'G19'       "$(v1_run config get satellite)"   "satellite carried over"
assert_eq 'ssa'       "$(v1_run config get sector)"      "sector carried over"
assert_eq '30'        "$(v1_run config get interval)"    "interval carried over"
assert_eq '7200x4320' "$(v1_run config get resolution)"  "resolution carried over"
assert_eq '5'         "$(v1_run config get keep_images)" "an invalid v1 value falls back to the default"

t::case "uninstall keeps settings by default"
UN="$T_SANDBOX/un"
mkdir -p "$UN/home/.local/bin"
un_run() {
  HOME="$UN/home" GOES_CONFIG_HOME="$UN/config" GOES_CACHE_HOME="$UN/cache" \
  GOES_STATE_HOME="$UN/state" XDG_CONFIG_HOME="$UN/xdg" XDG_DATA_HOME="$UN/data" \
    "$BASH" "$1/bin/goes" "${@:2}" 2>&1
}
seed_uninstall() {
  mkdir -p "$UN/config" "$UN/cache/images" "$UN/state"
  printf 'view=sector\nsatellite=G19\nsector=ssa\n' >"$UN/config/config"
  : >"$UN/cache/images/G19_ssa_GEOCOLOR_x.jpg"
  : >"$UN/state/goes-wallpaper.log"
}
seed_uninstall
ln -sf "$GOES_ROOT_DIR/bin/goes" "$UN/home/.local/bin/goes"
assert_contains "$(un_run "$GOES_ROOT_DIR" uninstall)" "Nothing was removed" \
  "without a terminal the confirmation defaults to no"
assert_file "$UN/config/config" "declining removes nothing"
out=$(un_run "$GOES_ROOT_DIR" uninstall --yes)
assert_contains "$out" "Uninstalled" "uninstall reports completion"
assert_no_file "$UN/cache" "downloaded images are removed"
assert_no_file "$UN/state" "logs and run state are removed"
assert_no_file "$UN/home/.local/bin/goes" "the command link is removed"
assert_file "$UN/config/config" "settings are kept"

t::case "purge never deletes a checkout the installer did not create"
seed_uninstall
out=$(un_run "$GOES_ROOT_DIR" uninstall --purge --yes)
assert_no_file "$UN/config" "settings are removed"
assert_file "$GOES_ROOT_DIR/bin/goes" "this development checkout is untouched"
assert_contains "$out" "not an installer-managed copy" "the user is told why it was kept"

t::case "purge removes an installer-managed copy"
seed_uninstall
MANAGED="$UN/data/goes-wallpaper"
mkdir -p "$MANAGED"
cp -R "$GOES_ROOT_DIR/bin" "$GOES_ROOT_DIR/lib" "$GOES_ROOT_DIR/share" "$MANAGED/"
out=$(un_run "$MANAGED" uninstall --purge --yes)
assert_contains "$out" "Program removed" "removal of the program is reported"
assert_no_file "$MANAGED" "the managed copy is deleted"
assert_no_file "$UN/config" "settings are removed"

t::case "uninstall rejects unknown options"
assert_status 1 "a bad flag is refused" "$BASH" "$GOES" uninstall --everything

# ── Network-dependent ────────────────────────────────────────────────────────
if [ "${GOES_NETWORK_TESTS:-0}" = "1" ]; then
  t::case "a real update writes state and logs"
  "$BASH" "$GOES" config set resolution 900x540 >/dev/null 2>&1
  out=$(run update --force); status=$?
  if [ "$status" -eq 0 ]; then
    assert_contains "$out" "900x540" "the update reports what it fetched"
  else
    # Headless CI has no desktop to paint; the failure must still be explicit.
    assert_contains "$out" "Could not set the wallpaper" "a headless failure is reported plainly"
  fi
  assert_file "$GOES_STATE_HOME/last-run" "run state is recorded"
  assert_file "$GOES_STATE_HOME/goes-wallpaper.log" "the log is written"
  assert_contains "$(run log)" "event=fetch_ok" "the download is logged in structured form"
  assert_contains "$(cat "$GOES_WALLPAPER_LOG" 2>/dev/null)" "$GOES_CACHE_HOME/images/G19_ssa_GEOCOLOR_" \
    "the test run went to the stub, never the real desktop"
  assert_contains "$(run status)" "ago" "status reports when it last ran"
fi

t::summary
