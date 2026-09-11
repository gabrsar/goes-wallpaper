#!/usr/bin/env bash
# Test runner. Each tests/test_*.sh file runs in its own process with its own
# sandbox, so one failing file cannot corrupt another.
#
#   tests/run.sh                 unit tests only (no network)
#   tests/run.sh --network       also hit NOAA
#   tests/run.sh test_config     run one file
#
# The suite is also run against /bin/bash when that is bash 3.2, because macOS
# ships 3.2 and most portability bugs only show up there.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export GOES_ROOT_DIR="$ROOT_DIR"
export GOES_LIB_DIR="$ROOT_DIR/lib"
export GOES_SHARE_DIR="$ROOT_DIR/share"
export GOES_TESTS_DIR="$TESTS_DIR"
export GOES_NETWORK_TESTS="${GOES_NETWORK_TESTS:-0}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[0m'; B=$'\033[1m'; GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; CYN=$'\033[36m'
else
  R=''; B=''; GRN=''; RED=''; DIM=''; CYN=''
fi

FILTER=''
for arg in "$@"; do
  case "$arg" in
    --network) export GOES_NETWORK_TESTS=1 ;;
    -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) FILTER="$arg" ;;
  esac
done

total_pass=0
total_fail=0
failed_files=''

printf '\n%sgoes-wallpaper test suite%s  %s(bash %s)%s\n' \
  "$B" "$R" "$DIM" "${BASH_VERSION%%(*}" "$R"
[ "$GOES_NETWORK_TESTS" = "1" ] && printf '%snetwork tests enabled%s\n' "$DIM" "$R"

for file in "$TESTS_DIR"/test_*.sh; do
  [ -f "$file" ] || continue
  name="$(basename "$file" .sh)"
  if [ -n "$FILTER" ]; then
    case "$name" in *"$FILTER"*) ;; *) continue ;; esac
  fi

  printf '\n%s%s%s\n' "$CYN" "$name" "$R"
  output=$("$BASH" "$file" 2>&1)
  status=$?
  printf '%s\n' "$output"

  # grep -c exits 1 on zero matches; keep the count and drop the status.
  p=$(printf '%s\n' "$output" | grep -c '^  ✔ '); p=${p:-0}
  f=$(printf '%s\n' "$output" | grep -c '^  ✘ '); f=${f:-0}
  total_pass=$((total_pass + p))
  total_fail=$((total_fail + f))
  [ "$status" -ne 0 ] && failed_files="$failed_files $name"
done

printf '\n'
printf '%s\n' "────────────────────────────────────────────"
if [ "$total_fail" -eq 0 ] && [ -z "$failed_files" ]; then
  printf '%s%s assertions passed%s\n' "$GRN" "$total_pass" "$R"
  exit 0
fi
printf '%s%s passed, %s failed%s\n' "$RED" "$total_pass" "$total_fail" "$R"
[ -n "$failed_files" ] && printf '%sfailing files:%s%s\n' "$RED" "$failed_files" "$R"
exit 1
