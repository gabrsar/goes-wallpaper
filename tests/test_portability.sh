#!/usr/bin/env bash
# Static checks that catch the portability bugs this project is prone to:
# bash-4-only syntax on a machine that ships bash 3.2, and byte sequences that
# bash 3.2 mis-parses.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox

cd "$GOES_ROOT_DIR" || exit 1
SHELL_FILES=$(ls lib/*.sh tests/*.sh bin/goes install.sh 2>/dev/null)
# Pattern checks skip the tests, which necessarily spell out the patterns.
SHIPPED_FILES=$(ls lib/*.sh bin/goes install.sh 2>/dev/null)

t::case "every script parses"
for f in $SHELL_FILES; do
  if "$BASH" -n "$f" 2>/dev/null; then
    t::_pass "$f parses"
  else
    t::_fail "$f parses" "$(bash -n "$f" 2>&1 | head -2)"
  fi
done

t::case "every script parses under bash 3.2"
if [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null; then
  for f in $SHELL_FILES; do
    if /bin/bash -n "$f" 2>/dev/null; then
      t::_pass "$f parses under bash 3.2"
    else
      t::_fail "$f parses under bash 3.2" "$(/bin/bash -n "$f" 2>&1 | head -2)"
    fi
  done
else
  t::_pass "skipped: no bash 3.2 at /bin/bash"
fi

t::case "no bash 4+ only syntax"
# Associative arrays, mapfile/readarray and ${x^^} all fail on macOS bash 3.2.
for pattern in 'declare -A' 'local -A' 'mapfile ' 'readarray ' '\${[A-Za-z_]*\^\^' '\${[A-Za-z_]*,,'; do
  hits=$(grep -nE "$pattern" $SHIPPED_FILES 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
  if [ -z "$hits" ]; then
    t::_pass "no use of '$pattern'"
  else
    t::_fail "no use of '$pattern'" "$(printf '%s' "$hits" | head -2)"
  fi
done

t::case "no fractional read timeouts outside the guarded helper"
hits=$(grep -n 'read .*-t 0\.' $SHIPPED_FILES 2>/dev/null | grep -v 'UI_ESC_TIMEOUT')
if [ -z "$hits" ]; then
  t::_pass "fractional timeouts are version-guarded"
else
  t::_fail "fractional timeouts are version-guarded" "$hits"
fi

t::case "local declarations never reference themselves"
# bash 3.2 expands every word of `local` before assigning any of them, so
# `local a=1 b="$a"` leaves b empty (or errors under set -u).
found=''
for f in $SHELL_FILES; do
  while IFS= read -r hit; do
    [ -n "$hit" ] && found="$found$f:$hit"$'\n'
  done <<EOT
$(awk '
  /^[[:space:]]*local[[:space:]]/ {
    line = $0
    sub(/^[[:space:]]*local[[:space:]]+/, "", line)
    n = split(line, words, /[[:space:]]+/)
    delete declared
    for (i = 1; i <= n; i++) {
      w = words[i]
      if (w ~ /\$/) {
        for (name in declared) {
          if (index(w, "$" name) || index(w, "${" name)) { print NR ": " $0; break }
        }
      }
      if (match(w, /^[A-Za-z_][A-Za-z0-9_]*=/)) {
        declared[substr(w, 1, RLENGTH - 1)] = 1
      }
    }
  }' "$f")
EOT
done
if [ -z "$found" ]; then
  t::_pass "no self-referencing local declarations"
else
  t::_fail "no self-referencing local declarations" "$(printf '%s' "$found" | head -3)"
fi

t::case "unbraced variables are never followed by non-ASCII bytes"
# bash 3.2 in a C locale swallows the leading byte of a multibyte character
# into the variable name, producing an 'unbound variable' error.
# awk is used because neither BSD grep nor grep -E can match raw high bytes
# reliably, and macOS grep has no -P.
found=$(for f in $SHELL_FILES; do
  LC_ALL=C awk -v f="$f" '/\$[A-Za-z_][A-Za-z0-9_]*[\200-\377]/ { print f ":" NR ": " $0 }' "$f"
done)
if [ -z "$found" ]; then
  t::_pass "every variable next to a glyph is braced"
else
  t::_fail "every variable next to a glyph is braced" "$(printf '%s' "$found" | head -3)"
fi

t::case "no GNU-only flags on BSD tools"
# These spellings work on GNU coreutils but fail on macOS. (stat -c is used,
# but only on the Linux branch of goes::mtime.)
for pattern in 'sed -i ' 'date -d ' 'readlink -f' 'grep -P'; do
  hits=$(grep -nE "$pattern" $SHIPPED_FILES 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
  if [ -z "$hits" ]; then
    t::_pass "no bare '$pattern'"
  else
    t::_fail "no bare '$pattern'" "$(printf '%s' "$hits" | head -2)"
  fi
done

t::case "executables have a shebang and the executable bit"
for f in bin/goes install.sh tests/run.sh; do
  head -1 "$f" | grep -q '^#!/usr/bin/env bash$' \
    && t::_pass "$f has a portable shebang" \
    || t::_fail "$f has a portable shebang" "$(head -1 "$f")"
  [ -x "$f" ] && t::_pass "$f is executable" || t::_fail "$f is executable"
done

t::case "libraries are guarded against double sourcing"
for f in lib/*.sh; do
  grep -q '_GOES_.*_SH:-' "$f" \
    && t::_pass "$(basename "$f") has an include guard" \
    || t::_fail "$(basename "$f") has an include guard"
done

t::case "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  out=$(shellcheck --severity=warning $SHELL_FILES 2>&1)
  if [ -z "$out" ]; then
    t::_pass "shellcheck reports no warnings"
  else
    t::_fail "shellcheck reports no warnings" "$(printf '%s' "$out" | head -8)"
  fi
else
  t::_pass "skipped: shellcheck is not installed"
fi

t::summary
