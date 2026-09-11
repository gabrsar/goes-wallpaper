#!/usr/bin/env bash
# The interactive picker on a real pseudo-terminal: keys in, screen out.
# Skipped when python3 is unavailable (it provides the pty).

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox

if ! command -v python3 >/dev/null 2>&1; then
  t::_pass "skipped: python3 is not installed"
  t::summary
  exit $?
fi

DRIVE="$GOES_TESTS_DIR/pty_drive.py"
SCENARIO="$T_SANDBOX/scenario.sh"

# A picker with headers, followed by a message on stderr: the message must
# still reach the terminal after the picker has closed its tty handle.
cat >"$SCENARIO" <<EOF
unset GOES_NONINTERACTIVE NO_COLOR
export LANG=en_US.UTF-8 FORCE_COLOR=1
. "$GOES_LIB_DIR/ui.sh"
UI_ITEMS=('Alaska' 'Hawaii' 'Great Lakes' 'Southeast')
UI_HINTS=('G18 ak' 'G18 hi' 'G19 cgl' 'G19 se')
UI_GROUPS=('West' 'West' 'East' 'East')
UI_TITLE='Pick one'
if ui::select; then
  goes::ok "picked=\${UI_ITEMS[\$UI_RESULT]}"
  exit 0
fi
goes::warn "cancelled"
exit 7
EOF

pick() {
  python3 "$DRIVE" --timeout 20 "$BASH" "$SCENARIO" -- "$@" 2>&1 \
    | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'
}

t::case "arrow keys move past group headers"
out=$(pick DOWN DOWN ENTER)
assert_contains "$out" "picked=Great Lakes" "two downs from Alaska skip the 'East' header"
assert_contains "$out" "Pick one" "the title is drawn"
assert_contains "$out" "West" "group headers are drawn"

t::case "messages after the picker still reach the terminal"
assert_contains "$out" "✔ picked=" "stderr is not swallowed once the picker closes"

t::case "typing filters the list"
out=$(pick s e ENTER ENTER)
assert_contains "$out" "filter: se" "the filter is shown as it is typed"
assert_contains "$out" "picked=Southeast" "Enter locks the filter, the next Enter picks"

t::case "End jumps to the last item"
assert_contains "$(pick END ENTER)" "picked=Southeast" "End selects the final item"

t::case "q cancels"
out=$(pick q)
assert_contains "$out" "cancelled" "the caller sees a cancellation"
assert_not_contains "$out" "picked=" "nothing is chosen"

t::case "Esc clears a filter before it cancels"
out=$(pick / z z z ESC SLEEP1.2 ENTER)
assert_contains "$out" "picked=Alaska" "after Esc clears the filter, Enter picks the first item"

t::case "the cursor is restored"
raw=$(python3 "$DRIVE" --timeout 20 "$BASH" "$SCENARIO" -- ENTER 2>&1)
case "$raw" in
  *$'\033[?25h'*) t::_pass "the cursor is shown again on exit" ;;
  *) t::_fail "the cursor is shown again on exit" ;;
esac

t::summary
