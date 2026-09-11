#!/usr/bin/env bash
# Configuration parsing, validation, persistence and v1 migration.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox
. "$GOES_LIB_DIR/config.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
t::case "defaults"
config::load
assert_eq 'sector'   "$CFG_view"        "view defaults to sector"
assert_eq 'GEOCOLOR' "$CFG_product"     "product defaults to GEOCOLOR"
assert_eq 'auto'     "$CFG_resolution"  "resolution defaults to auto"
assert_eq '10'       "$CFG_interval"    "interval defaults to 10"
assert_eq 'skip'     "$CFG_on_battery"  "on_battery defaults to skip"
assert_eq 'fit'      "$CFG_scaling"     "scaling defaults to fit"
assert_status 1 "is_configured is false with no satellite" config::is_configured

# ── Validation ───────────────────────────────────────────────────────────────
t::case "validation"
assert_ok   "view=fd accepted"            config::validate view fd
assert_ok   "view=sector accepted"        config::validate view sector
assert_fail "view=planet rejected"        config::validate view planet
assert_ok   "satellite=G19 accepted"      config::validate satellite G19
assert_ok   "empty satellite accepted"    config::validate satellite ''
assert_fail "satellite=GOES19 rejected"   config::validate satellite GOES19
assert_fail "satellite=g19 rejected"      config::validate satellite g19
assert_ok   "sector=ssa accepted"         config::validate sector ssa
assert_fail "sector with digits rejected" config::validate sector ss1
assert_ok   "resolution=auto accepted"    config::validate resolution auto
assert_ok   "resolution=3600x2160 ok"     config::validate resolution 3600x2160
assert_fail "resolution=huge rejected"    config::validate resolution huge
assert_fail "resolution=3600X2160 case"   config::validate resolution 3600X2160
assert_ok   "interval=1 accepted"         config::validate interval 1
assert_ok   "interval=1440 accepted"      config::validate interval 1440
assert_fail "interval=0 rejected"         config::validate interval 0
assert_fail "interval=1441 rejected"      config::validate interval 1441
assert_fail "interval=ten rejected"       config::validate interval ten
assert_ok   "keep_images=1 accepted"      config::validate keep_images 1
assert_fail "keep_images=0 rejected"      config::validate keep_images 0
assert_fail "keep_images=201 rejected"    config::validate keep_images 201
assert_ok   "scaling=fill accepted"       config::validate scaling fill
assert_fail "scaling=cover rejected"      config::validate scaling cover
assert_fail "unknown key rejected"        config::validate nonsense x

t::case "set rejects invalid values"
config::load
assert_fail "set interval 0 fails"  config::set interval 0
assert_eq '10' "$CFG_interval" "value unchanged after a rejected set"
config::set interval 30
assert_eq '0' "$?" "set interval 30 works"
assert_eq '30' "$CFG_interval" "value updated after an accepted set"

# ── Round trip ───────────────────────────────────────────────────────────────
t::case "save and load round trip"
config::load
config::set view sector
config::set satellite G18
config::set sector pnw
config::set resolution 1800x1080
config::set interval 15
config::set scaling fill
config::set keep_images 12
config::save
assert_file "$GOES_CONFIG_FILE" "config file written"

# Wipe in-memory state, then read it back from disk.
CFG_satellite=''; CFG_sector=''; CFG_interval=''
config::load
assert_eq 'G18'        "$CFG_satellite"  "satellite survives a round trip"
assert_eq 'pnw'        "$CFG_sector"     "sector survives a round trip"
assert_eq '1800x1080'  "$CFG_resolution" "resolution survives a round trip"
assert_eq '15'         "$CFG_interval"   "interval survives a round trip"
assert_eq 'fill'       "$CFG_scaling"    "scaling survives a round trip"
assert_eq '12'         "$CFG_keep_images" "keep_images survives a round trip"
assert_ok "is_configured is true once saved" config::is_configured
assert_eq 'G18 sector pnw' "$(config::describe)" "describe reads naturally"

t::case "file permissions"
perms=$(ls -l "$GOES_CONFIG_FILE" | cut -c1-10)
assert_eq '-rw-------' "$perms" "config is not world readable"

# ── Hostile / broken input ───────────────────────────────────────────────────
t::case "malformed config is survivable"
cat >"$GOES_CONFIG_FILE" <<'CFG'
# a comment
view=sector
satellite = G19
  sector  =  ssa
resolution="2400x2400"
interval=notanumber
nonsense=whatever
this line has no equals sign
keep_images=7
CFG
config::load 2>/dev/null
assert_eq 'G19'       "$CFG_satellite"  "whitespace around '=' is tolerated"
assert_eq 'ssa'       "$CFG_sector"     "leading whitespace is tolerated"
assert_eq '2400x2400' "$CFG_resolution" "quoted values are unquoted"
assert_eq '10'        "$CFG_interval"   "invalid interval falls back to the default"
assert_eq '7'         "$CFG_keep_images" "later keys still parse after a bad line"

t::case "config cannot execute code"
CANARY="$T_SANDBOX/pwned"
cat >"$GOES_CONFIG_FILE" <<CFG
view=\$(touch "$CANARY")
satellite=\`touch "$CANARY"\`
sector=ssa;touch "$CANARY"
CFG
config::load 2>/dev/null
assert_no_file "$CANARY" "command substitution in the config never runs"
assert_eq 'sector' "$CFG_view" "an injected view value is rejected"

t::case "an empty config file is fine"
: >"$GOES_CONFIG_FILE"
config::load 2>/dev/null
assert_eq '10' "$CFG_interval" "defaults apply to an empty file"

# ── v1 migration ─────────────────────────────────────────────────────────────
t::case "migration from the v1 layout"
rm -f "$GOES_CONFIG_FILE"
printf 'G19\n'       >"$XDG_CONFIG_HOME/goes-sat"
printf 'ssa&src=nav\n' >"$XDG_CONFIG_HOME/goes-sector"
printf 'largest\n'   >"$XDG_CONFIG_HOME/goes-resolution"
printf '5\n'         >"$XDG_CONFIG_HOME/goes-interval"
printf '9\n'         >"$XDG_CONFIG_HOME/goes-keep-images"

config::load
assert_ok "legacy files are detected" config::legacy_present
config::migrate_legacy
assert_eq '0' "$?" "migration succeeds"
assert_eq 'G19'  "$CFG_satellite"  "satellite is imported"
assert_eq 'ssa'  "$CFG_sector"     "URL cruft is stripped from the sector"
assert_eq 'auto' "$CFG_resolution" "'largest' maps to 'auto'"
assert_eq '5'    "$CFG_interval"   "interval is imported"
assert_eq '9'    "$CFG_keep_images" "keep_images is imported"

t::case "legacy files are archived, not deleted"
config::archive_legacy 2>/dev/null
assert_no_file "$XDG_CONFIG_HOME/goes-sat" "the old file is moved out of the way"
assert_file "$GOES_CONFIG_DIR/legacy-v1/goes-sat" "the old file is kept as a backup"
assert_status 1 "legacy_present is false afterwards" config::legacy_present

t::summary
