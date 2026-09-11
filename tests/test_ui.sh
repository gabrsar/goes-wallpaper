#!/usr/bin/env bash
# Picker internals: text layout, filtering, and cursor movement over a list
# that mixes group headers with selectable items.

set -uo pipefail
. "$GOES_TESTS_DIR/lib.sh"
t::sandbox
. "$GOES_LIB_DIR/ui.sh"

# ── Text helpers ─────────────────────────────────────────────────────────────
t::case "truncate"
assert_eq 'hello'  "$(ui::truncate 'hello' 10)" "short text is untouched"
assert_eq 'hello'  "$(ui::truncate 'hello' 5)"  "exact-width text is untouched"
assert_eq 'hel…'   "$(ui::truncate 'hello' 4)"  "long text gets an ellipsis"
assert_eq 'h'      "$(ui::truncate 'hello' 1)"  "width 1 yields one character"
assert_eq ''       "$(ui::truncate '' 5)"       "empty stays empty"

t::case "truncate without unicode"
GOES_UNICODE=0
assert_eq 'hel~' "$(ui::truncate 'hello' 4)" "ASCII terminals get a tilde"
GOES_UNICODE=1

t::case "pad"
assert_eq 'ab   ' "$(ui::pad 'ab' 5)"  "short text is padded"
assert_eq 'abcde' "$(ui::pad 'abcde' 5)" "exact-width text is unchanged"
assert_eq 'abcdef' "$(ui::pad 'abcdef' 3)" "over-wide text is never truncated by pad"

# ── Display list ─────────────────────────────────────────────────────────────
setup_list() {
  UI_ITEMS=('Alaska' 'Central Alaska' 'Hawaii' 'Northern Pacific' 'Great Lakes')
  UI_HINTS=('G18 ak' 'G18 cak' 'G18 hi' 'G18 np' 'G19 cgl')
  UI_GROUPS=('Alaska' 'Alaska' 'Pacific' 'Pacific' 'United States')
}

t::case "display list interleaves headers with items"
setup_list
ui::_build_display ''
assert_eq '8' "$UI_D_COUNT" "5 items plus 3 group headers"
assert_eq 'h' "${UI_D_TYPE[0]}" "the list opens with a header"
assert_eq 'Alaska' "${UI_D_TEXT[0]}" "the first header names the first group"
assert_eq 'i' "${UI_D_TYPE[1]}" "the first item follows its header"
assert_eq '0' "${UI_D_IDX[1]}" "items keep their original index"
assert_eq '-1' "${UI_D_IDX[0]}" "headers carry no item index"

t::case "measuring column widths"
setup_list
ui::_measure
assert_eq '16' "$UI_MAX_LABEL" "the longest label sets the label column"
assert_eq '7'  "$UI_MAX_HINT"  "the longest hint sets the hint column"

t::case "filtering by label"
setup_list
ui::_build_display 'alaska'
assert_eq '3' "$UI_D_COUNT" "one header plus two matching items"
assert_eq 'Alaska' "${UI_D_TEXT[1]}" "Alaska matches"
assert_eq 'Central Alaska' "${UI_D_TEXT[2]}" "Central Alaska matches"

t::case "filtering is case insensitive"
setup_list
ui::_build_display 'HAWAII'
assert_eq '2' "$UI_D_COUNT" "an uppercase filter still matches"
assert_eq 'Hawaii' "${UI_D_TEXT[1]}" "the right item survives"

t::case "filtering also searches hints and groups"
setup_list
ui::_build_display 'cgl'
assert_eq '2' "$UI_D_COUNT" "a sector code in the hint matches"
setup_list
ui::_build_display 'pacific'
assert_eq '3' "$UI_D_COUNT" "a group name matches its items"

t::case "a filter matching nothing yields an empty list"
setup_list
ui::_build_display 'zzzzz'
assert_eq '0' "$UI_D_COUNT" "nothing is displayed"
assert_eq '-1' "$(ui::_first_item_line)" "there is no first item"
assert_eq '-1' "$(ui::_last_item_line)" "there is no last item"

t::case "items without groups render flat"
UI_ITEMS=('one' 'two'); UI_HINTS=('' ''); UI_GROUPS=('' '')
ui::_build_display ''
assert_eq '2' "$UI_D_COUNT" "no headers are inserted"
assert_eq '0' "$(ui::_first_item_line)" "the first line is the first item"

# ── Cursor movement ──────────────────────────────────────────────────────────
t::case "movement skips headers"
setup_list
ui::_build_display ''
first=$(ui::_first_item_line)
assert_eq '1' "$first" "the cursor starts on the first item, not the header"
assert_eq '2' "$(ui::_move "$first" 1)" "moving down lands on the next item"
# Display line 2 is the last Alaska item; the next item is past a header.
assert_eq '4' "$(ui::_move 2 1)" "moving down jumps over an intervening header"
assert_eq '2' "$(ui::_move 4 -1)" "moving up jumps back over the header"

t::case "movement clamps at the ends"
setup_list
ui::_build_display ''
first=$(ui::_first_item_line)
last=$(ui::_last_item_line)
assert_eq '7' "$last" "the last item is the final display line"
assert_eq "$first" "$(ui::_move "$first" -1)" "moving up from the top stays put"
assert_eq "$last"  "$(ui::_move "$last" 1)"   "moving down from the bottom stays put"
assert_eq "$last"  "$(ui::_move "$first" 99)" "a large jump clamps to the end"
assert_eq "$first" "$(ui::_move "$last" -99)" "a large jump back clamps to the start"

t::case "paging moves by whole items"
setup_list
ui::_build_display ''
assert_eq '5' "$(ui::_move 1 3)" "a three-item page skips the headers in between"

# ── Non-interactive behavior ────────────────────────────────────────────────
t::case "no terminal means no interactive picker"
assert_status 1 "GOES_NONINTERACTIVE disables the picker" ui::interactive

t::case "a single option needs no prompt"
UI_ITEMS=('only'); UI_HINTS=(''); UI_GROUPS=('')
ui::select
assert_eq '0' "$?" "select returns immediately"
assert_eq '0' "$UI_RESULT" "the only option is chosen"

t::case "an empty list is an error"
UI_ITEMS=(); UI_HINTS=(); UI_GROUPS=()
assert_status 1 "select refuses an empty list" ui::select

t::case "confirm falls back to its default without a terminal"
assert_ok   "default yes is accepted" ui::confirm "proceed?" y
assert_fail "default no is declined"  ui::confirm "proceed?" n

t::case "ask falls back to its default without a terminal"
assert_eq '42' "$(ui::ask 'how many' 42)" "the default value is returned"

t::summary
