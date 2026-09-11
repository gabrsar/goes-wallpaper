#!/usr/bin/env bash
# Satellite/region catalog: NOAA scraping, grouping, URL building and the
# resolution chooser.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox
. "$GOES_LIB_DIR/catalog.sh"

FIXTURES="$GOES_TESTS_DIR/fixtures"

# ── Scraping ─────────────────────────────────────────────────────────────────
t::case "parsing the NOAA navigation menu"
parsed=$(catalog::parse_index "$FIXTURES/noaa-index.html")
count=$(printf '%s\n' "$parsed" | grep -c '	')
assert_eq '31' "$count" "every region in the fixture is found"
assert_contains "$parsed" "G19	ssa	South America - Southern" "sector code and name are paired"
assert_contains "$parsed" "G18	hi	Hawaii" "GOES-West regions are found too"
assert_not_contains "$parsed" "src=nav" "query-string cruft is stripped"
assert_not_contains "$parsed" "<span" "markup is stripped from names"

t::case "a page with no regions yields nothing"
printf '<html><body>maintenance</body></html>\n' >"$T_SANDBOX/empty.html"
empty=$(catalog::parse_index "$T_SANDBOX/empty.html")
assert_eq '' "$empty" "an unrecognizable page parses to nothing"

# ── Built-in fallback ────────────────────────────────────────────────────────
t::case "the built-in catalog is usable on its own"
builtin_count=$(catalog::builtin | grep -c '	')
assert_eq '31' "$builtin_count" "the built-in catalog covers every region"
assert_contains "$(catalog::builtin)" "G19	ssa" "the built-in catalog has South America"

t::case "loading falls back to the built-in list when offline"
# An unreachable host forces every network path to fail.
GOES_SITE_BASE="https://127.0.0.1:9/GOES" GOES_CONNECT_TIMEOUT=1 GOES_RETRIES=1 \
  catalog::load 2>/dev/null
assert_eq 'builtin' "$CAT_SOURCE" "the source is reported as built-in"
assert_eq '31' "$CAT_COUNT" "all regions are still available offline"

t::case "loaded entries are grouped and sorted"
assert_eq 'United States' "${CAT_GROUP[0]}" "United States sorts first"
last=$((CAT_COUNT - 1))
assert_eq 'Oceans' "${CAT_GROUP[$last]}" "Oceans sorts last"
assert_eq 'South America - Southern' "$(catalog::sector_name G19 ssa)" "codes resolve to names"
assert_eq 'zz' "$(catalog::sector_name G19 zz)" "an unknown code returns itself"

t::case "satellite list"
sats=$(catalog::satellites | tr '\n' ' ')
assert_eq 'G19 G18 ' "$sats" "GOES-East is offered before GOES-West"

# ── Metadata ─────────────────────────────────────────────────────────────────
t::case "satellite metadata"
assert_eq 'GOES-East' "$(catalog::sat_label G19)" "G19 is GOES-East"
assert_eq 'GOES-West' "$(catalog::sat_label G18)" "G18 is GOES-West"
assert_eq 'G99'       "$(catalog::sat_label G99)" "an unknown satellite echoes its code"
assert_eq '75.2°W'    "$(catalog::sat_position G19)" "G19 orbital slot"
assert_eq 'GOES19'    "$(catalog::cdn_sat G19)" "CDN path segment for G19"
assert_eq 'GOES16'    "$(catalog::cdn_sat G16)" "CDN path segment for G16"

t::case "region grouping"
assert_eq 'United States'    "$(catalog::group_for eus)" "eus is a US region"
assert_eq 'South America'    "$(catalog::group_for ssa)" "ssa is South America"
assert_eq 'Alaska'           "$(catalog::group_for cak)" "cak is Alaska"
assert_eq 'Other regions'    "$(catalog::group_for zzz)" "unknown codes get a catch-all group"
assert_eq '1' "$(catalog::group_rank 'United States')" "United States ranks first"
assert_eq '9' "$(catalog::group_rank 'Other regions')" "the catch-all ranks last"

# ── URLs ─────────────────────────────────────────────────────────────────────
t::case "CDN URL construction"
assert_eq 'https://cdn.star.nesdis.noaa.gov/GOES19/ABI/SECTOR/ssa/GEOCOLOR' \
  "$(catalog::image_dir_url G19 sector ssa GEOCOLOR)" "sector URL"
assert_eq 'https://cdn.star.nesdis.noaa.gov/GOES19/ABI/FD/GEOCOLOR' \
  "$(catalog::image_dir_url G19 fd '' GEOCOLOR)" "full-disk URL ignores the sector"
assert_eq 'https://cdn.star.nesdis.noaa.gov/GOES18/ABI/SECTOR/hi/GEOCOLOR' \
  "$(catalog::image_dir_url G18 sector hi)" "product defaults to GEOCOLOR"

# ── Resolution selection ─────────────────────────────────────────────────────
t::case "choosing a resolution under a pixel ceiling"
LIST='470717616	21696x21696
117679404	10848x10848
29419851	5424x5424
3268864	1808x1808
459684	678x678
114921	339x339'
assert_eq '5424x5424' "$(printf '%s\n' "$LIST" | catalog::pick_resolution 30000000)" \
  "picks the largest frame under 30 MP"
assert_eq '1808x1808' "$(printf '%s\n' "$LIST" | catalog::pick_resolution 4000000)" \
  "picks the largest frame under 4 MP"
assert_eq '21696x21696' "$(printf '%s\n' "$LIST" | catalog::pick_resolution 999999999)" \
  "picks the largest frame when the ceiling is huge"
assert_eq '339x339' "$(printf '%s\n' "$LIST" | catalog::pick_resolution 1000)" \
  "falls back to the smallest when everything exceeds the ceiling"
assert_eq '5424x5424' "$(printf '%s\n' "$LIST" | catalog::pick_resolution 29419851)" \
  "the ceiling is inclusive"
assert_eq '21696x21696' "$(printf '%s\n' "$LIST" | catalog::pick_resolution 0)" \
  "no ceiling (0) means the largest frame"
assert_eq '21696x21696' "$(printf '%s\n' "$LIST" | catalog::pick_resolution)" \
  "no argument means the largest frame"

# ── Network-dependent ────────────────────────────────────────────────────────
if [ "${GOES_NETWORK_TESTS:-0}" = "1" ]; then
  t::case "live CDN listing"
  live=$(catalog::resolutions "$(catalog::image_dir_url G19 sector ssa GEOCOLOR)")
  assert_contains "$live" "x" "NOAA returns resolutions"
  best=$(printf '%s\n' "$live" | catalog::pick_resolution 30000000)
  assert_contains "$best" "x" "a resolution is chosen from live data"

  t::case "live catalog refresh"
  catalog::load --refresh
  assert_eq 'noaa' "$CAT_SOURCE" "the catalog comes from NOAA"
  assert_ne '0' "$CAT_COUNT" "regions were discovered"
fi

t::summary
