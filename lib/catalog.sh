#!/usr/bin/env bash
# The catalog of satellites, regions and image resolutions offered by NOAA.
#
# A built-in catalog ships with the program so that `setup` always works, even
# offline or if NOAA restyles their markup. When the network is available the
# catalog is refreshed from star.nesdis.noaa.gov and cached for a day.

[ -n "${_GOES_CATALOG_SH:-}" ] && return 0
_GOES_CATALOG_SH=1

# shellcheck source=lib/net.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/net.sh"

GOES_CDN_BASE="${GOES_CDN_BASE:-https://cdn.star.nesdis.noaa.gov}"
GOES_SITE_BASE="${GOES_SITE_BASE:-https://www.star.nesdis.noaa.gov/GOES}"
GOES_CATALOG_TTL="${GOES_CATALOG_TTL:-86400}"

# Parallel arrays populated by catalog::load (bash 3.2 has no hash maps).
CAT_SAT=(); CAT_SECTOR=(); CAT_NAME=(); CAT_GROUP=()
CAT_COUNT=0
CAT_SOURCE=''

# ── Satellite metadata ───────────────────────────────────────────────────────
catalog::sat_label() {
  case "$1" in
    G19) printf 'GOES-East' ;;
    G18) printf 'GOES-West' ;;
    G16) printf 'GOES-East (retired)' ;;
    G17) printf 'GOES-West (standby)' ;;
    *)   printf '%s' "$1" ;;
  esac
}

catalog::sat_position() {
  case "$1" in
    G19) printf '75.2°W' ;;
    G18) printf '137.0°W' ;;
    G16) printf '75.2°W' ;;
    G17) printf '104.7°W' ;;
    *)   printf 'unknown' ;;
  esac
}

catalog::sat_blurb() {
  case "$1" in
    G19) printf 'North & South America, the Atlantic, the Caribbean' ;;
    G18) printf 'Western North America, Alaska, Hawaii, the Pacific' ;;
    G16) printf 'Former GOES-East; imagery may be stale' ;;
    G17) printf 'On-orbit standby; imagery may be stale' ;;
    *)   printf '' ;;
  esac
}

catalog::cdn_sat() {
  printf 'GOES%s' "${1#G}"
}

# ── Region grouping ──────────────────────────────────────────────────────────
catalog::group_for() {
  case "$1" in
    eus|ne|se|cgl|umv|smv|sp|nr|sr|ga|gwas|wus|pnw|psw) printf 'United States' ;;
    ak|cak|sea)                                          printf 'Alaska' ;;
    hi|np|tpw|tsp)                                       printf 'Hawaii & Pacific' ;;
    can)                                                 printf 'Canada' ;;
    mex|cam)                                             printf 'Mexico & Central America' ;;
    car|pr)                                              printf 'Caribbean' ;;
    nsa|ssa)                                             printf 'South America' ;;
    na|taw|eep)                                          printf 'Oceans' ;;
    *)                                                   printf 'Other regions' ;;
  esac
}

catalog::group_rank() {
  case "$1" in
    'United States')             printf '1' ;;
    'Canada')                    printf '2' ;;
    'Mexico & Central America')  printf '3' ;;
    'Caribbean')                 printf '4' ;;
    'South America')             printf '5' ;;
    'Alaska')                    printf '6' ;;
    'Hawaii & Pacific')          printf '7' ;;
    'Oceans')                    printf '8' ;;
    *)                           printf '9' ;;
  esac
}

# ── Built-in catalog ─────────────────────────────────────────────────────────
catalog::builtin() {
  cat <<'TSV'
G19	eus	U.S. Atlantic Coast
G19	ne	Northeast
G19	se	Southeast
G19	cgl	Great Lakes
G19	umv	Upper Mississippi Valley
G19	smv	Southern Mississippi Valley
G19	sp	Southern Plains
G19	nr	Northern Rockies
G19	sr	Southern Rockies
G19	ga	Gulf of America
G19	can	Canada/Northern U.S.
G19	mex	Mexico
G19	cam	Central America
G19	car	Caribbean
G19	pr	Puerto Rico
G19	nsa	South America - Northern
G19	ssa	South America - Southern
G19	na	Northern Atlantic
G19	taw	Tropical Atlantic
G19	eep	Eastern East Pacific
G18	gwas	GOES-West - All States
G18	wus	U.S. Pacific Coast
G18	pnw	Pacific Northwest
G18	psw	Pacific Southwest
G18	ak	Alaska
G18	cak	Central Alaska
G18	sea	Southeastern Alaska
G18	hi	Hawaii
G18	np	Northern Pacific
G18	tpw	Tropical Pacific
G18	tsp	South Pacific
TSV
}

# ── Live discovery ───────────────────────────────────────────────────────────
# Emits `SAT<TAB>SECTOR<TAB>NAME` scraped from the NOAA navigation menu.
catalog::parse_index() {
  grep -oE "<li><a href='sector\.php\?sat=G[0-9]+&sector=[a-z]+&amp;src=nav'>[^<]+" "$1" \
    | sed -E "s|<li><a href='sector\.php\?sat=(G[0-9]+)&sector=([a-z]+)&amp;src=nav'>|\1	\2	|" \
    | sed -E 's/[[:space:]]+$//' \
    | grep -vE '	$' \
    | sort -u
}

catalog::_cache_is_fresh() {
  [ -s "$GOES_CATALOG_CACHE" ] || return 1
  local age
  age=$(( $(date +%s) - $(goes::mtime "$GOES_CATALOG_CACHE") ))
  [ "$age" -lt "$GOES_CATALOG_TTL" ]
}

# catalog::refresh [--force]
# Returns 0 when the cache holds freshly discovered data, 1 when the built-in
# catalog should be used instead.
catalog::refresh() {
  local force=0
  [ "${1:-}" = "--force" ] && force=1

  if [ "$force" -eq 0 ] && catalog::_cache_is_fresh; then
    return 0
  fi

  mkdir -p "$GOES_CACHE_DIR" || return 1
  local page parsed
  page="$GOES_CACHE_DIR/index.html"

  net::get "$GOES_SITE_BASE/" "$page" || return 1
  parsed=$(catalog::parse_index "$page")
  rm -f "$page"

  # A handful of entries means the markup changed; prefer the built-in list
  # over a half-parsed one.
  local n
  n=$(printf '%s\n' "$parsed" | grep -c '	' 2>/dev/null || printf '0')
  [ "$n" -lt 10 ] && { goes::log warn "event=catalog_parse_thin entries=$n"; return 1; }

  printf '%s\n' "$parsed" >"$GOES_CATALOG_CACHE" || return 1
  goes::log info "event=catalog_refreshed entries=$n"
  return 0
}

# catalog::load [--refresh | --offline]
# Fills CAT_* arrays, sorted by region group then name. --offline never
# touches the network (for commands like `status` that must stay instant).
catalog::load() {
  local mode="${1:-}"

  local raw=''
  if [ "$mode" = "--offline" ]; then
    if [ -s "$GOES_CATALOG_CACHE" ]; then
      raw=$(cat "$GOES_CATALOG_CACHE"); CAT_SOURCE='cache'
    else
      raw=$(catalog::builtin); CAT_SOURCE='builtin'
    fi
  elif [ "$mode" = "--refresh" ] && catalog::refresh --force; then
    raw=$(cat "$GOES_CATALOG_CACHE")
    CAT_SOURCE='noaa'
  elif catalog::_cache_is_fresh; then
    raw=$(cat "$GOES_CATALOG_CACHE")
    CAT_SOURCE='cache'
  elif catalog::refresh; then
    raw=$(cat "$GOES_CATALOG_CACHE")
    CAT_SOURCE='noaa'
  else
    raw=$(catalog::builtin)
    CAT_SOURCE='builtin'
  fi

  CAT_SAT=(); CAT_SECTOR=(); CAT_NAME=(); CAT_GROUP=(); CAT_COUNT=0

  local sorted sat sector name group
  sorted=$(printf '%s\n' "$raw" | while IFS='	' read -r sat sector name; do
    [ -z "$sat" ] && continue
    [ -z "$sector" ] && continue
    group=$(catalog::group_for "$sector")
    printf '%s\t%s\t%s\t%s\t%s\n' "$(catalog::group_rank "$group")" "$name" "$sat" "$sector" "$group"
  done | LC_ALL=C sort -t'	' -k1,1n -k2,2f)

  local _rank
  while IFS='	' read -r _rank name sat sector group; do
    [ -z "$sat" ] && continue
    CAT_SAT[$CAT_COUNT]="$sat"
    CAT_SECTOR[$CAT_COUNT]="$sector"
    CAT_NAME[$CAT_COUNT]="$name"
    CAT_GROUP[$CAT_COUNT]="$group"
    CAT_COUNT=$((CAT_COUNT + 1))
  done <<EOT
$sorted
EOT
}

catalog::sector_name() {
  local sat="$1" sector="$2" i=0
  while [ "$i" -lt "$CAT_COUNT" ]; do
    if [ "${CAT_SAT[$i]}" = "$sat" ] && [ "${CAT_SECTOR[$i]}" = "$sector" ]; then
      printf '%s' "${CAT_NAME[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  printf '%s' "$sector"
}

# Unique satellite codes present in the loaded catalog, most capable first.
catalog::satellites() {
  local i=0 seen=''
  while [ "$i" -lt "$CAT_COUNT" ]; do
    case " $seen " in
      *" ${CAT_SAT[$i]} "*) ;;
      *) seen="$seen ${CAT_SAT[$i]}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' $seen | LC_ALL=C sort -r
}

# ── Image URLs ───────────────────────────────────────────────────────────────
# catalog::image_dir_url SAT VIEW SECTOR PRODUCT
catalog::image_dir_url() {
  local sat="$1" view="$2" sector="$3" product="${4:-GEOCOLOR}"
  local cdn_sat
  cdn_sat=$(catalog::cdn_sat "$sat")
  if [ "$view" = "fd" ]; then
    printf '%s/%s/ABI/FD/%s' "$GOES_CDN_BASE" "$cdn_sat" "$product"
  else
    printf '%s/%s/ABI/SECTOR/%s/%s' "$GOES_CDN_BASE" "$cdn_sat" "$sector" "$product"
  fi
}

# catalog::resolutions DIR_URL
# Prints `PIXELS<TAB>WxH`, largest first. NOAA keeps a `WIDTHxHEIGHT.jpg` file
# in each directory that always points at the most recent frame.
catalog::resolutions() {
  local url="$1" tmp out
  tmp=$(mktemp "${TMPDIR:-/tmp}/goes-res.XXXXXX") || return 1
  if ! net::get "$url/" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  out=$(grep -oE '"[0-9]{2,6}x[0-9]{2,6}\.jpg"' "$tmp" \
    | tr -d '"' | sed 's/\.jpg$//' | LC_ALL=C sort -u \
    | while IFS= read -r res; do
        [ -z "$res" ] && continue
        printf '%s\t%s\n' "$(( ${res%x*} * ${res#*x} ))" "$res"
      done | LC_ALL=C sort -rn)
  rm -f "$tmp"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# catalog::pick_resolution MAX_PIXELS <<< resolution list (largest first)
# Chooses the largest resolution; MAX_PIXELS > 0 caps it, falling back to the
# smallest available when every option is over the cap.
catalog::pick_resolution() {
  local max="${1:-0}" pixels res best='' smallest=''
  while IFS='	' read -r pixels res; do
    [ -z "$res" ] && continue
    smallest="$res"
    if [ -z "$best" ] && { [ "$max" -eq 0 ] || [ "$pixels" -le "$max" ]; }; then
      best="$res"
    fi
  done
  if [ -n "$best" ]; then printf '%s' "$best"; else printf '%s' "$smallest"; fi
}
