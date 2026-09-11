#!/usr/bin/env bash
# HTTP helpers built on curl, with retry/backoff and a real User-Agent.
#
# NOAA's CDN occasionally 5xxes or stalls mid-transfer; every request here is
# bounded in time and retried, so a transient failure never wedges the service.

[ -n "${_GOES_NET_SH:-}" ] && return 0
_GOES_NET_SH=1

# shellcheck source=lib/common.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/common.sh"

GOES_USER_AGENT="goes-wallpaper/$GOES_VERSION (+$GOES_REPO_WEB)"
GOES_CONNECT_TIMEOUT="${GOES_CONNECT_TIMEOUT:-10}"
GOES_MAX_TIME="${GOES_MAX_TIME:-120}"
GOES_RETRIES="${GOES_RETRIES:-3}"

net::_curl() {
  curl --silent --show-error --location \
       --user-agent "$GOES_USER_AGENT" \
       --connect-timeout "$GOES_CONNECT_TIMEOUT" \
       --max-time "$GOES_MAX_TIME" \
       --retry 0 \
       "$@"
}

# net::get URL OUTFILE [extra curl args...]
# Writes the body to OUTFILE only on a 2xx response, so a failed request can
# never leave a half-written file that later looks like a valid image.
net::get() {
  local url="$1" out="$2"; shift 2
  local attempt=1 delay=2 code tmp
  tmp="$out.part.$$"

  while [ "$attempt" -le "$GOES_RETRIES" ]; do
    code=$(net::_curl --output "$tmp" --write-out '%{http_code}' "$@" "$url" 2>/dev/null) || code="000"

    if [ "$code" = "200" ] || [ "$code" = "206" ]; then
      mv -f "$tmp" "$out" && return 0
      rm -f "$tmp"
      goes::log error "event=http_move_failed url=$url out=$out"
      return 1
    fi

    if [ "$code" = "304" ]; then
      rm -f "$tmp"
      return 3
    fi

    # 4xx other than 408/429 will not fix themselves; stop burning time.
    case "$code" in
      4*) [ "$code" = "408" ] || [ "$code" = "429" ] || break ;;
    esac

    goes::log warn "event=http_retry url=$url code=$code attempt=$attempt"
    rm -f "$tmp"
    [ "$attempt" -lt "$GOES_RETRIES" ] && sleep "$delay"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done

  rm -f "$tmp"
  goes::log error "event=http_failed url=$url code=$code attempts=$GOES_RETRIES"
  NET_LAST_CODE="$code"
  return 1
}

# net::fetch URL  — body on stdout, empty + non-zero on failure.
net::fetch() {
  local url="$1" tmp status
  tmp=$(mktemp "${TMPDIR:-/tmp}/goes-net.XXXXXX") || return 1
  if net::get "$url" "$tmp"; then
    cat "$tmp"
    status=0
  else
    status=1
  fi
  rm -f "$tmp"
  return $status
}

# True when NOAA's CDN answers at all. Any HTTP status counts: the point is
# that DNS, TLS and routing work, not that a particular path exists.
net::online() {
  local code
  code=$(net::_curl --head --max-time 8 --output /dev/null \
         --write-out '%{http_code}' "https://cdn.star.nesdis.noaa.gov/GOES19/" 2>/dev/null) || return 1
  printf '%s' "$code" | grep -qE '^[1-5][0-9][0-9]$'
}

# Size of a remote resource in bytes, or empty when the server does not say.
net::content_length() {
  local url="$1" hdr len
  hdr=$(mktemp "${TMPDIR:-/tmp}/goes-head.XXXXXX") || return 1
  net::_curl --head --max-time 20 --output /dev/null --dump-header "$hdr" "$url" >/dev/null 2>&1
  len=$(grep -i '^content-length:' "$hdr" 2>/dev/null | tail -1 \
        | sed -E 's/^[Cc]ontent-[Ll]ength:[[:space:]]*//' | tr -d '\r')
  rm -f "$hdr"
  printf '%s' "$len" | grep -qE '^[0-9]+$' || return 1
  printf '%s' "$len"
}
