#!/usr/bin/env bash
# Shared primitives: paths, terminal styling, logging, error handling.
#
# Compatibility note: this project targets bash 3.2 (the version Apple ships).
# No associative arrays, no `mapfile`, no `${var^^}`, no `&>>`.

[ -n "${_GOES_COMMON_SH:-}" ] && return 0
_GOES_COMMON_SH=1

GOES_PROG="goes"
GOES_NAME="goes-wallpaper"
GOES_VERSION="2.0.0"
GOES_REPO_WEB="https://github.com/gabrsar/goes-wallpaper"

# Layout of the installed tree. bin/goes exports GOES_LIB_DIR before sourcing.
GOES_LIB_DIR="${GOES_LIB_DIR:?GOES_LIB_DIR must be set}"
GOES_ROOT_DIR="${GOES_ROOT_DIR:-$(cd "$GOES_LIB_DIR/.." && pwd)}"
GOES_SHARE_DIR="${GOES_SHARE_DIR:-$GOES_ROOT_DIR/share}"

GOES_CONFIG_DIR="${GOES_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/goes-wallpaper}"
GOES_CACHE_DIR="${GOES_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/goes-wallpaper}"
GOES_STATE_DIR="${GOES_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/goes-wallpaper}"

GOES_CONFIG_FILE="$GOES_CONFIG_DIR/config"
GOES_IMAGE_DIR="$GOES_CACHE_DIR/images"
GOES_CATALOG_CACHE="$GOES_CACHE_DIR/catalog.tsv"
GOES_LOG_FILE="$GOES_STATE_DIR/goes-wallpaper.log"
GOES_STATUS_FILE="$GOES_STATE_DIR/last-run"
GOES_CURRENT_LINK="$GOES_STATE_DIR/current.jpg"

GOES_LOG_MAX_BYTES=1048576

goes::platform() {
  case "${OSTYPE:-$(uname -s)}" in
    darwin*|Darwin*) printf 'macos' ;;
    linux*|Linux*)   printf 'linux' ;;
    *)               printf 'unsupported' ;;
  esac
}

GOES_PLATFORM="$(goes::platform)"

# ── Terminal styling ─────────────────────────────────────────────────────────
# Colors are enabled only for a real terminal, and always suppressed by NO_COLOR
# (https://no-color.org). FORCE_COLOR overrides the tty check for CI/pipelines.
goes::init_colors() {
  local enable=0
  if [ -n "${FORCE_COLOR:-}" ]; then
    enable=1
  elif [ -z "${NO_COLOR:-}" ] && [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
    enable=1
  fi

  if [ "$enable" -eq 1 ]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';    C_DIM=$'\033[2m'
    C_RED=$'\033[31m';   C_GREEN=$'\033[32m';  C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
    C_WHITE=$'\033[37m'; C_GREY=$'\033[90m'
    C_BG_BLUE=$'\033[44m'; C_BG_CYAN=$'\033[46m'
    GOES_COLOR=1
  else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''
    C_BLUE=''; C_MAGENTA=''; C_CYAN=''
    C_WHITE=''; C_GREY=''
    C_BG_BLUE=''; C_BG_CYAN=''
    GOES_COLOR=0
  fi
}
goes::init_colors

# Unicode is used for the picker chrome; ASCII is substituted when the locale
# cannot represent it, otherwise the menu renders as mojibake.
if printf '%s' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" | grep -qiE 'utf-?8'; then
  GOES_UNICODE=1
  GOES_GLYPH_OK='✔'; GOES_GLYPH_FAIL='✘'; GOES_GLYPH_WARN='▲'
  GOES_GLYPH_INFO='•'; GOES_GLYPH_ARROW='▸'; GOES_GLYPH_DOT='·'
  GOES_GLYPH_UP='↑';  GOES_GLYPH_DOWN='↓'
else
  GOES_UNICODE=0
  GOES_GLYPH_OK='[ok]'; GOES_GLYPH_FAIL='[!!]'; GOES_GLYPH_WARN='[/\]'
  GOES_GLYPH_INFO='*'; GOES_GLYPH_ARROW='>'; GOES_GLYPH_DOT='-'
  GOES_GLYPH_UP='^';  GOES_GLYPH_DOWN='v'
fi

# ── Console output ───────────────────────────────────────────────────────────
# Everything except explicit command results goes to stderr so that commands
# which print machine-readable values on stdout stay pipeable.
goes::say()  { printf '%s\n' "$*" >&2; }
goes::ok()   { printf '%s%s%s %s\n' "$C_GREEN" "$GOES_GLYPH_OK" "$C_RESET" "$*" >&2; }
goes::info() { printf '%s%s%s %s\n' "$C_CYAN" "$GOES_GLYPH_INFO" "$C_RESET" "$*" >&2; }
goes::warn() { printf '%s%s %s%s\n' "$C_YELLOW" "$GOES_GLYPH_WARN" "$*" "$C_RESET" >&2; }
goes::err()  { printf '%s%s %s%s\n' "$C_RED" "$GOES_GLYPH_FAIL" "$*" "$C_RESET" >&2; }
goes::hint() { printf '%s  %s%s\n' "$C_GREY" "$*" "$C_RESET" >&2; }

goes::die() {
  goes::err "$*"
  exit 1
}

goes::heading() {
  printf '\n%s%s%s%s\n' "$C_BOLD" "$C_WHITE" "$*" "$C_RESET" >&2
}

goes::rule() {
  local width="${1:-56}" line=''
  local i=0
  while [ "$i" -lt "$width" ]; do
    if [ "$GOES_UNICODE" -eq 1 ]; then line="${line}─"; else line="${line}-"; fi
    i=$((i + 1))
  done
  printf '%s%s%s\n' "$C_GREY" "$line" "$C_RESET" >&2
}

# ── Structured file logging ──────────────────────────────────────────────────
# Format is `ts=... level=... event=... key=value`, greppable and parseable.
goes::log() {
  local level="$1"; shift
  goes::_rotate_log
  mkdir -p "$(dirname "$GOES_LOG_FILE")" 2>/dev/null || return 0
  printf 'ts=%s level=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" >>"$GOES_LOG_FILE"
}

goes::_rotate_log() {
  [ -f "$GOES_LOG_FILE" ] || return 0
  local size
  size=$(goes::file_size "$GOES_LOG_FILE")
  [ "$size" -gt "$GOES_LOG_MAX_BYTES" ] 2>/dev/null || return 0
  mv -f "$GOES_LOG_FILE" "$GOES_LOG_FILE.1" 2>/dev/null || true
}

goes::file_size() {
  local f="$1"
  [ -f "$f" ] || { printf '0'; return 0; }
  # `wc -c` is the only byte-count spelling that behaves identically on BSD/GNU.
  wc -c <"$f" | tr -d ' '
}

goes::have() { command -v "$1" >/dev/null 2>&1; }

goes::require() {
  local missing='' cmd
  for cmd in "$@"; do
    goes::have "$cmd" || missing="$missing $cmd"
  done
  [ -z "$missing" ] && return 0
  goes::err "Missing required command(s):$missing"
  return 1
}

goes::ensure_dirs() {
  mkdir -p "$GOES_CONFIG_DIR" "$GOES_IMAGE_DIR" "$GOES_STATE_DIR" || return 1
}

# Human-readable byte count without relying on numfmt (absent on macOS).
goes::human_bytes() {
  local b="${1:-0}"
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    printf '%s.%s GB' "$((b / 1073741824))" "$(((b % 1073741824) * 10 / 1073741824))"
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    printf '%s.%s MB' "$((b / 1048576))" "$(((b % 1048576) * 10 / 1048576))"
  elif [ "$b" -ge 1024 ] 2>/dev/null; then
    printf '%s KB' "$((b / 1024))"
  else
    printf '%s B' "$b"
  fi
}

goes::relative_time() {
  local then_epoch="${1:-0}" now delta
  now=$(date +%s)
  delta=$((now - then_epoch))
  [ "$delta" -lt 0 ] && delta=0
  if   [ "$delta" -lt 60 ];    then printf '%ss ago' "$delta"
  elif [ "$delta" -lt 3600 ];  then printf '%sm ago' "$((delta / 60))"
  elif [ "$delta" -lt 86400 ]; then printf '%sh %sm ago' "$((delta / 3600))" "$(((delta % 3600) / 60))"
  else printf '%sd ago' "$((delta / 86400))"
  fi
}

goes::mtime() {
  local f="$1"
  [ -e "$f" ] || { printf '0'; return 0; }
  if [ "$GOES_PLATFORM" = "macos" ]; then
    stat -f %m "$f" 2>/dev/null || printf '0'
  else
    stat -c %Y "$f" 2>/dev/null || printf '0'
  fi
}
