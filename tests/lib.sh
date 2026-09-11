#!/usr/bin/env bash
# Minimal assertion library for the test suite. No external dependencies: the
# tests must run on a bare macOS or Linux box with nothing installed.

T_PASS=0
T_FAIL=0
T_FAILURES=''
T_CURRENT=''

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  T_R=$'\033[0m'; T_GRN=$'\033[32m'; T_RED=$'\033[31m'; T_DIM=$'\033[2m'; T_B=$'\033[1m'
else
  T_R=''; T_GRN=''; T_RED=''; T_DIM=''; T_B=''
fi

t::case() { T_CURRENT="$1"; }

t::_pass() {
  T_PASS=$((T_PASS + 1))
  printf '  %s✔%s %s\n' "$T_GRN" "$T_R" "$1"
}

t::_fail() {
  T_FAIL=$((T_FAIL + 1))
  printf '  %s✘%s %s\n' "$T_RED" "$T_R" "$1"
  [ -n "${2:-}" ] && printf '      %s%s%s\n' "$T_DIM" "$2" "$T_R"
  T_FAILURES="$T_FAILURES
  $T_CURRENT: $1"
}

assert_eq() {
  local expected="$1" actual="$2" label="${3:-values match}"
  if [ "$expected" = "$actual" ]; then
    t::_pass "$label"
  else
    t::_fail "$label" "expected '$expected', got '$actual'"
  fi
}

assert_ne() {
  local unexpected="$1" actual="$2" label="${3:-values differ}"
  if [ "$unexpected" != "$actual" ]; then
    t::_pass "$label"
  else
    t::_fail "$label" "did not expect '$unexpected'"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-output contains '$2'}"
  case "$haystack" in
    *"$needle"*) t::_pass "$label" ;;
    *) t::_fail "$label" "'$needle' not found in: $(printf '%s' "$haystack" | head -3)" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="${3:-output lacks '$2'}"
  case "$haystack" in
    *"$needle"*) t::_fail "$label" "unexpectedly found '$needle'" ;;
    *) t::_pass "$label" ;;
  esac
}

# assert_status EXPECTED_CODE LABEL COMMAND...
assert_status() {
  local expected="$1" label="$2"; shift 2
  local output actual
  output=$("$@" 2>&1); actual=$?
  if [ "$actual" -eq "$expected" ]; then
    t::_pass "$label"
  else
    t::_fail "$label" "expected exit $expected, got $actual: $(printf '%s' "$output" | head -2)"
  fi
}

assert_ok()   { local label="$1"; shift; assert_status 0 "$label" "$@"; }
assert_fail() { local label="$1"; shift
  local output actual
  output=$("$@" 2>&1); actual=$?
  if [ "$actual" -ne 0 ]; then t::_pass "$label"
  else t::_fail "$label" "expected failure, got exit 0"; fi
}

assert_file() {
  local path="$1" label="${2:-$1 exists}"
  if [ -f "$path" ]; then t::_pass "$label"; else t::_fail "$label" "no such file"; fi
}

assert_no_file() {
  local path="$1" label="${2:-$1 does not exist}"
  if [ ! -e "$path" ]; then t::_pass "$label"; else t::_fail "$label" "file exists"; fi
}

# Creates an isolated config/cache/state tree for one test file and removes it
# on exit, so tests can never touch the developer's real installation.
t::sandbox() {
  T_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/goes-test.XXXXXX")
  export GOES_CONFIG_HOME="$T_SANDBOX/config"
  export GOES_CACHE_HOME="$T_SANDBOX/cache"
  export GOES_STATE_HOME="$T_SANDBOX/state"
  export XDG_CONFIG_HOME="$T_SANDBOX/xdg-config"
  export GOES_NONINTERACTIVE=1
  export NO_COLOR=1
  mkdir -p "$GOES_CONFIG_HOME" "$GOES_CACHE_HOME" "$GOES_STATE_HOME" "$XDG_CONFIG_HOME"

  # Never touch the developer's desktop or real scheduler: wallpaper changes
  # go to a recorder, and service names are unique to this run.
  export GOES_WALLPAPER_LOG="$T_SANDBOX/wallpaper-calls"
  printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s"\n' "$GOES_WALLPAPER_LOG" >"$T_SANDBOX/set-wallpaper-stub"
  chmod +x "$T_SANDBOX/set-wallpaper-stub"
  export GOES_WALLPAPER_CMD="$T_SANDBOX/set-wallpaper-stub"
  export GOES_LAUNCHD_LABEL="com.github.gabrsar.goes-wallpaper.test-$$"
  export GOES_SYSTEMD_UNIT="goes-wallpaper-test-$$"
  trap 't::cleanup' EXIT
}

t::cleanup() {
  [ -n "${T_SANDBOX:-}" ] && [ -d "$T_SANDBOX" ] && rm -rf "$T_SANDBOX"
  return 0
}

t::summary() {
  printf '\n'
  if [ "$T_FAIL" -eq 0 ]; then
    printf '%s%s passed%s\n' "$T_GRN" "$T_PASS" "$T_R"
    return 0
  fi
  printf '%s%s passed, %s failed%s\n' "$T_RED" "$T_PASS" "$T_FAIL" "$T_R"
  return 1
}
