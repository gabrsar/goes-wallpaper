#!/usr/bin/env bash
# Interactive terminal UI: a scrolling, filterable, keyboard-driven picker plus
# prompts and a spinner.
#
# All interaction happens on /dev/tty rather than stdin, so the UI still works
# when the program itself is being piped in (`curl ... | bash`).

[ -n "${_GOES_UI_SH:-}" ] && return 0
_GOES_UI_SH=1

# shellcheck source=lib/common.sh
. "${GOES_LIB_DIR:?GOES_LIB_DIR must be set}/common.sh"

UI_TTY="/dev/tty"
UI_RESULT=-1

# bash 3.2 rejects fractional `read -t`. With a 1s timeout a bare Esc still
# works, it just takes a moment; arrow keys are unaffected because their bytes
# are already buffered by the terminal.
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then
  UI_ESC_TIMEOUT="0.05"
else
  UI_ESC_TIMEOUT="1"
fi

# `-r /dev/tty` is true even without a controlling terminal; only opening it
# tells the truth.
ui::_tty_usable() {
  ( exec 3<"$UI_TTY" ) 2>/dev/null
}

ui::interactive() {
  [ -n "${GOES_NONINTERACTIVE:-}" ] && return 1
  ui::_tty_usable
}

ui::term_cols() {
  local c
  c=$(tput cols 2>/dev/null) || c=''
  [ -n "$c" ] && [ "$c" -gt 20 ] 2>/dev/null || c=80
  printf '%s' "$c"
}

ui::term_lines() {
  local l
  l=$(tput lines 2>/dev/null) || l=''
  [ -n "$l" ] && [ "$l" -gt 8 ] 2>/dev/null || l=24
  printf '%s' "$l"
}

ui::_hide_cursor() { [ "$GOES_COLOR" -eq 1 ] && printf '\033[?25l' >"$UI_TTY"; }
ui::_show_cursor() { [ "$GOES_COLOR" -eq 1 ] && printf '\033[?25h' >"$UI_TTY"; }

# Truncate to a column budget, appending an ellipsis when text is cut.
ui::truncate() {
  local text="$1" width="$2"
  if [ "${#text}" -le "$width" ]; then
    printf '%s' "$text"
  elif [ "$width" -gt 1 ]; then
    printf '%s%s' "${text:0:$((width - 1))}" "$([ "$GOES_UNICODE" -eq 1 ] && printf '…' || printf '~')"
  else
    printf '%s' "${text:0:$width}"
  fi
}

ui::pad() {
  # bash 3.2 expands every word of `local` before assigning any of them, so
  # `out` cannot be initialized from `text` on the same line.
  local text="$1" width="$2" out
  out="$text"
  while [ "${#out}" -lt "$width" ]; do out="$out "; done
  printf '%s' "$out"
}

# ── Key input ────────────────────────────────────────────────────────────────
# Prints a symbolic key name: up down left right enter esc backspace tab
# home end pgup pgdn, or `char:X`.
ui::_read_key() {
  local k rest extra
  IFS= read -rsn1 k <&3 || { printf 'eof'; return 0; }
  case "$k" in
    '')
      printf 'enter' ;;
    $'\033')
      if IFS= read -rsn2 -t "$UI_ESC_TIMEOUT" rest <&3 && [ -n "$rest" ]; then
        case "$rest" in
          '[A'|'OA') printf 'up' ;;
          '[B'|'OB') printf 'down' ;;
          '[C'|'OC') printf 'right' ;;
          '[D'|'OD') printf 'left' ;;
          '[H'|'OH') printf 'home' ;;
          '[F'|'OF') printf 'end' ;;
          '[5') IFS= read -rsn1 -t "$UI_ESC_TIMEOUT" extra <&3; printf 'pgup' ;;
          '[6') IFS= read -rsn1 -t "$UI_ESC_TIMEOUT" extra <&3; printf 'pgdn' ;;
          '[1'|'[7') IFS= read -rsn1 -t "$UI_ESC_TIMEOUT" extra <&3; printf 'home' ;;
          '[4'|'[8') IFS= read -rsn1 -t "$UI_ESC_TIMEOUT" extra <&3; printf 'end' ;;
          *) printf 'esc' ;;
        esac
      else
        printf 'esc'
      fi ;;
    $'\177'|$'\010') printf 'backspace' ;;
    $'\t') printf 'tab' ;;
    $'\003') printf 'interrupt' ;;
    *) printf 'char:%s' "$k" ;;
  esac
}

# ── Picker ───────────────────────────────────────────────────────────────────
# Caller fills:
#   UI_ITEMS[]   required  display label
#   UI_HINTS[]   optional  dim right-aligned annotation
#   UI_GROUPS[]  optional  group name; a header is drawn when it changes
#   UI_TITLE     optional  heading
#   UI_SUBTITLE  optional  one line under the heading
#   UI_INITIAL   optional  index to start on
# Sets UI_RESULT to the chosen index; returns 1 if cancelled.
UI_ITEMS=(); UI_HINTS=(); UI_GROUPS=()
UI_TITLE=''; UI_SUBTITLE=''; UI_INITIAL=0

UI_MAX_LABEL=0
UI_MAX_HINT=0

ui::_measure() {
  local i=0
  UI_MAX_LABEL=0; UI_MAX_HINT=0
  while [ "$i" -lt "${#UI_ITEMS[@]}" ]; do
    [ "${#UI_ITEMS[$i]}" -gt "$UI_MAX_LABEL" ] && UI_MAX_LABEL="${#UI_ITEMS[$i]}"
    local h="${UI_HINTS[$i]:-}"
    [ "${#h}" -gt "$UI_MAX_HINT" ] && UI_MAX_HINT="${#h}"
    i=$((i + 1))
  done
}

ui::select() {
  local count="${#UI_ITEMS[@]}"
  UI_RESULT=-1
  ui::_measure
  [ "$count" -eq 0 ] && { goes::err "nothing to choose from"; return 1; }
  if [ "$count" -eq 1 ]; then
    UI_RESULT=0
    return 0
  fi
  if ! ui::interactive; then
    ui::_select_fallback
    return $?
  fi
  ui::_select_interactive
}

ui::_select_fallback() {
  local i=0 count="${#UI_ITEMS[@]}" answer group last_group=''
  [ -n "$UI_TITLE" ] && printf '\n%s%s%s\n' "$C_BOLD" "$UI_TITLE" "$C_RESET" >&2
  [ -n "$UI_SUBTITLE" ] && printf '%s%s%s\n' "$C_GREY" "$UI_SUBTITLE" "$C_RESET" >&2
  while [ "$i" -lt "$count" ]; do
    group="${UI_GROUPS[$i]:-}"
    if [ -n "$group" ] && [ "$group" != "$last_group" ]; then
      printf '\n  %s%s%s\n' "$C_BOLD" "$group" "$C_RESET" >&2
      last_group="$group"
    fi
    printf '  %3d) %s %s%s%s\n' "$((i + 1))" "${UI_ITEMS[$i]}" \
      "$C_GREY" "${UI_HINTS[$i]:-}" "$C_RESET" >&2
    i=$((i + 1))
  done
  printf '\n' >&2

  local default=$((UI_INITIAL + 1))
  while :; do
    printf 'Select [1-%s] (default %s): ' "$count" "$default" >&2
    if ui::_tty_usable; then
      IFS= read -r answer <"$UI_TTY" || return 1
    else
      IFS= read -r answer || return 1
    fi
    [ -z "$answer" ] && answer="$default"
    if printf '%s' "$answer" | grep -qE '^[0-9]+$' \
       && [ "$answer" -ge 1 ] && [ "$answer" -le "$count" ]; then
      UI_RESULT=$((answer - 1))
      return 0
    fi
    goes::err "Enter a number between 1 and $count."
  done
}

# Display-line model: headers and items share one list so that scrolling and
# the viewport stay exact regardless of how many headers are on screen.
UI_D_TYPE=(); UI_D_TEXT=(); UI_D_IDX=(); UI_D_COUNT=0

ui::_build_display() {
  local filter="$1" i=0 last_group='' group label hint hay
  UI_D_TYPE=(); UI_D_TEXT=(); UI_D_IDX=(); UI_D_COUNT=0
  local lower_filter
  lower_filter=$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')

  while [ "$i" -lt "${#UI_ITEMS[@]}" ]; do
    label="${UI_ITEMS[$i]}"
    hint="${UI_HINTS[$i]:-}"
    group="${UI_GROUPS[$i]:-}"
    if [ -n "$lower_filter" ]; then
      hay=$(printf '%s %s %s' "$label" "$hint" "$group" | tr '[:upper:]' '[:lower:]')
      case "$hay" in
        *"$lower_filter"*) ;;
        *) i=$((i + 1)); continue ;;
      esac
    fi
    if [ -n "$group" ] && [ "$group" != "$last_group" ]; then
      UI_D_TYPE[$UI_D_COUNT]='h'
      UI_D_TEXT[$UI_D_COUNT]="$group"
      UI_D_IDX[$UI_D_COUNT]=-1
      UI_D_COUNT=$((UI_D_COUNT + 1))
      last_group="$group"
    fi
    UI_D_TYPE[$UI_D_COUNT]='i'
    UI_D_TEXT[$UI_D_COUNT]="$label"
    UI_D_IDX[$UI_D_COUNT]="$i"
    UI_D_COUNT=$((UI_D_COUNT + 1))
    i=$((i + 1))
  done
}

ui::_first_item_line() {
  local d=0
  while [ "$d" -lt "$UI_D_COUNT" ]; do
    [ "${UI_D_TYPE[$d]}" = 'i' ] && { printf '%s' "$d"; return 0; }
    d=$((d + 1))
  done
  printf '%s' '-1'
}

ui::_last_item_line() {
  local d=$((UI_D_COUNT - 1))
  while [ "$d" -ge 0 ]; do
    [ "${UI_D_TYPE[$d]}" = 'i' ] && { printf '%s' "$d"; return 0; }
    d=$((d - 1))
  done
  printf '%s' '-1'
}

ui::_select_interactive() {
  exec 3<"$UI_TTY"
  local restore_trap='ui::_show_cursor; exec 3<&- 2>/dev/null'
  # shellcheck disable=SC2064
  trap "$restore_trap; trap - INT TERM EXIT; exit 130" INT TERM
  ui::_hide_cursor

  local filter='' filtering=0 cursor=0 top=0 drawn=0
  local cols rows view_h key ch status=1

  ui::_build_display ''
  cursor=$(ui::_first_item_line)
  # Honor UI_INITIAL by locating its display line.
  local d=0
  while [ "$d" -lt "$UI_D_COUNT" ]; do
    if [ "${UI_D_TYPE[$d]}" = 'i' ] && [ "${UI_D_IDX[$d]}" -eq "${UI_INITIAL:-0}" ]; then
      cursor="$d"; break
    fi
    d=$((d + 1))
  done

  while :; do
    cols=$(ui::term_cols)
    rows=$(ui::term_lines)
    view_h=$((rows - 8))
    [ "$view_h" -lt 3 ] && view_h=3
    [ "$view_h" -gt "$UI_D_COUNT" ] && view_h="$UI_D_COUNT"

    # Keep the cursor inside the viewport.
    [ "$cursor" -lt "$top" ] && top="$cursor"
    [ "$cursor" -ge $((top + view_h)) ] && top=$((cursor - view_h + 1))
    [ "$top" -lt 0 ] && top=0
    local max_top=$((UI_D_COUNT - view_h))
    [ "$max_top" -lt 0 ] && max_top=0
    [ "$top" -gt "$max_top" ] && top="$max_top"

    [ "$drawn" -gt 0 ] && printf '\033[%sA\033[J' "$drawn" >"$UI_TTY"
    drawn=$(ui::_draw "$cols" "$view_h" "$top" "$cursor" "$filter" "$filtering")

    key=$(ui::_read_key)
    case "$key" in
      up)    cursor=$(ui::_move "$cursor" -1) ;;
      down)  cursor=$(ui::_move "$cursor" 1) ;;
      pgup)  cursor=$(ui::_move "$cursor" "-$view_h") ;;
      pgdn)  cursor=$(ui::_move "$cursor" "$view_h") ;;
      home)  cursor=$(ui::_first_item_line) ;;
      end)   cursor=$(ui::_last_item_line) ;;
      enter)
        if [ "$filtering" -eq 1 ]; then
          filtering=0
        elif [ "$cursor" -ge 0 ] && [ "$cursor" -lt "$UI_D_COUNT" ]; then
          UI_RESULT="${UI_D_IDX[$cursor]}"
          status=0
          break
        fi ;;
      esc)
        if [ "$filtering" -eq 1 ] || [ -n "$filter" ]; then
          filter=''; filtering=0
          ui::_build_display ''
          cursor=$(ui::_first_item_line); top=0
        else
          break
        fi ;;
      interrupt|eof) break ;;
      backspace)
        if [ -n "$filter" ]; then
          filter="${filter%?}"
          filtering=1
          ui::_build_display "$filter"
          cursor=$(ui::_first_item_line); top=0
        fi ;;
      char:/)
        filtering=1 ;;
      char:*)
        ch="${key#char:}"
        if [ "$filtering" -eq 1 ]; then
          filter="$filter$ch"
          ui::_build_display "$filter"
          cursor=$(ui::_first_item_line); top=0
        else
          case "$ch" in
            k) cursor=$(ui::_move "$cursor" -1) ;;
            j) cursor=$(ui::_move "$cursor" 1) ;;
            g) cursor=$(ui::_first_item_line) ;;
            G) cursor=$(ui::_last_item_line) ;;
            q) break ;;
            ' ')
              if [ "$cursor" -ge 0 ]; then
                UI_RESULT="${UI_D_IDX[$cursor]}"; status=0; break
              fi ;;
            *)
              filtering=1
              filter="$filter$ch"
              ui::_build_display "$filter"
              cursor=$(ui::_first_item_line); top=0 ;;
          esac
        fi ;;
    esac
    [ "$cursor" -lt 0 ] && cursor=$(ui::_first_item_line)
  done

  [ "$drawn" -gt 0 ] && printf '\033[%sA\033[J' "$drawn" >"$UI_TTY"
  ui::_show_cursor
  exec 3<&- 2>/dev/null
  trap - INT TERM
  return $status
}

# Move the cursor by N item rows, skipping headers and clamping at the ends.
ui::_move() {
  local pos="$1" delta="$2" step dir
  if [ "$delta" -lt 0 ]; then dir=-1; step=$((-delta)); else dir=1; step="$delta"; fi
  local i=0 candidate
  while [ "$i" -lt "$step" ]; do
    candidate=$((pos + dir))
    while [ "$candidate" -ge 0 ] && [ "$candidate" -lt "$UI_D_COUNT" ] \
          && [ "${UI_D_TYPE[$candidate]}" != 'i' ]; do
      candidate=$((candidate + dir))
    done
    if [ "$candidate" -lt 0 ] || [ "$candidate" -ge "$UI_D_COUNT" ]; then
      break
    fi
    pos="$candidate"
    i=$((i + 1))
  done
  printf '%s' "$pos"
}

# Draws the picker and echoes the number of terminal lines it occupied.
ui::_draw() {
  local cols="$1" view_h="$2" top="$3" cursor="$4" filter="$5" filtering="$6"
  local out='' lines=0 d idx hint body
  # Columns are sized to the content: labels get what they need, hints sit
  # immediately after, and both shrink together on a narrow terminal.
  local hint_w="$UI_MAX_HINT"
  [ "$hint_w" -gt 44 ] && hint_w=44
  local body_w="$UI_MAX_LABEL"
  local avail=$((cols - 8 - hint_w - 2))
  [ "$body_w" -gt "$avail" ] && body_w="$avail"
  [ "$body_w" -lt 12 ] && body_w=12
  local label_w=$((body_w + hint_w + 2))

  if [ -n "$UI_TITLE" ]; then
    out="$out$C_BOLD$C_WHITE$UI_TITLE$C_RESET"$'\n'
    lines=$((lines + 1))
  fi
  if [ -n "$UI_SUBTITLE" ]; then
    out="$out$C_GREY$(ui::truncate "$UI_SUBTITLE" "$cols")$C_RESET"$'\n'
    lines=$((lines + 1))
  fi
  out="$out"$'\n'; lines=$((lines + 1))

  if [ "$top" -gt 0 ]; then
    out="$out  $C_GREY$GOES_GLYPH_UP $top more$C_RESET"$'\n'
  else
    out="$out"$'\n'
  fi
  lines=$((lines + 1))

  d="$top"
  local shown=0
  while [ "$shown" -lt "$view_h" ] && [ "$d" -lt "$UI_D_COUNT" ]; do
    if [ "${UI_D_TYPE[$d]}" = 'h' ]; then
      out="$out  $C_BOLD$C_BLUE$(ui::truncate "${UI_D_TEXT[$d]}" "$label_w")$C_RESET"$'\n'
    else
      idx="${UI_D_IDX[$d]}"
      hint="${UI_HINTS[$idx]:-}"
      body=$(ui::pad "$(ui::truncate "${UI_D_TEXT[$d]}" "$body_w")" "$body_w")
      hint="$(ui::truncate "$hint" "$hint_w")"
      if [ "$d" -eq "$cursor" ]; then
        out="$out   $C_CYAN$GOES_GLYPH_ARROW$C_RESET $C_BOLD$C_CYAN$body$C_RESET $C_GREY$hint$C_RESET"$'\n'
      else
        out="$out     $body $C_GREY$hint$C_RESET"$'\n'
      fi
    fi
    d=$((d + 1)); shown=$((shown + 1)); lines=$((lines + 1))
  done

  local remaining=$((UI_D_COUNT - d))
  if [ "$remaining" -gt 0 ]; then
    out="$out  $C_GREY$GOES_GLYPH_DOWN $remaining more$C_RESET"$'\n'
  else
    out="$out"$'\n'
  fi
  lines=$((lines + 1))

  out="$out"$'\n'; lines=$((lines + 1))
  if [ "$filtering" -eq 1 ] || [ -n "$filter" ]; then
    out="$out  ${C_YELLOW}filter:${C_RESET} ${filter}"
    [ "$filtering" -eq 1 ] && out="$out${C_CYAN}_${C_RESET}"
    out="$out   $C_GREY(Esc clears, enter locks in)$C_RESET"$'\n'
  else
    out="$out  $C_GREY$GOES_GLYPH_UP$GOES_GLYPH_DOWN move  $GOES_GLYPH_DOT  enter select  $GOES_GLYPH_DOT  / filter  $GOES_GLYPH_DOT  q cancel$C_RESET"$'\n'
  fi
  lines=$((lines + 1))

  printf '%s' "$out" >"$UI_TTY"
  printf '%s' "$lines"
}

# ── Prompts ──────────────────────────────────────────────────────────────────
ui::confirm() {
  local prompt="$1" default="${2:-y}" answer suffix
  if [ "$default" = "y" ]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
  if ! ui::interactive; then
    [ "$default" = "y" ]
    return $?
  fi
  while :; do
    printf '%s%s%s %s%s%s ' "$C_BOLD" "$prompt" "$C_RESET" "$C_GREY" "$suffix" "$C_RESET" >"$UI_TTY"
    IFS= read -r answer <"$UI_TTY" || { printf '\n' >"$UI_TTY"; return 1; }
    [ -z "$answer" ] && answer="$default"
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
      *) goes::err "Please answer y or n." ;;
    esac
  done
}

# ui::ask PROMPT DEFAULT [VALIDATOR_FN]
# The validator receives the candidate value and must return 0 to accept.
ui::ask() {
  local prompt="$1" default="$2" validator="${3:-}" answer
  if ! ui::interactive; then
    printf '%s' "$default"
    return 0
  fi
  while :; do
    if [ -n "$default" ]; then
      printf '%s%s%s %s(%s)%s: ' "$C_BOLD" "$prompt" "$C_RESET" "$C_GREY" "$default" "$C_RESET" >"$UI_TTY"
    else
      printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET" >"$UI_TTY"
    fi
    IFS= read -r answer <"$UI_TTY" || { printf '%s' "$default"; return 0; }
    [ -z "$answer" ] && answer="$default"
    if [ -z "$validator" ] || "$validator" "$answer"; then
      printf '%s' "$answer"
      return 0
    fi
  done
}

# ── Spinner ──────────────────────────────────────────────────────────────────
UI_SPINNER_PID=''
UI_SPINNER_MSG=''

ui::spin_start() {
  UI_SPINNER_MSG="$1"
  if [ ! -t 2 ] || [ "$GOES_COLOR" -eq 0 ]; then
    printf '%s%s%s %s...\n' "$C_CYAN" "$GOES_GLYPH_INFO" "$C_RESET" "$UI_SPINNER_MSG" >&2
    UI_SPINNER_PID=''
    return 0
  fi
  (
    local frames='|/-\\' i=0
    [ "$GOES_UNICODE" -eq 1 ] && frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while :; do
      printf '\r%s%s%s %s ' "$C_CYAN" "$(printf '%s' "$frames" | cut -c$((i % 10 + 1)))" "$C_RESET" "$UI_SPINNER_MSG" >&2
      i=$((i + 1))
      sleep 0.08
    done
  ) 2>/dev/null &
  UI_SPINNER_PID=$!
}

# ui::spin_stop STATUS [MESSAGE]  — STATUS 0 prints a check, anything else an X.
ui::spin_stop() {
  local status="${1:-0}" msg="${2:-$UI_SPINNER_MSG}"
  if [ -n "$UI_SPINNER_PID" ]; then
    kill "$UI_SPINNER_PID" 2>/dev/null
    wait "$UI_SPINNER_PID" 2>/dev/null
    UI_SPINNER_PID=''
    printf '\r\033[K' >&2
  fi
  if [ "$status" -eq 0 ]; then
    goes::ok "$msg"
  else
    goes::err "$msg"
  fi
}

ui::banner() {
  local sub="${1:-}"
  printf '\n' >&2
  if [ "$GOES_UNICODE" -eq 1 ]; then
    printf '%s%s  ◜◝  GOES Wallpaper%s %sv%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_GREY" "$GOES_VERSION" "$C_RESET" >&2
    printf '%s  ◟◞  %s%s\n' "$C_GREY" "$sub" "$C_RESET" >&2
  else
    printf '%s  GOES Wallpaper%s %sv%s%s\n' "$C_BOLD" "$C_RESET" "$C_GREY" "$GOES_VERSION" "$C_RESET" >&2
    printf '%s  %s%s\n' "$C_GREY" "$sub" "$C_RESET" >&2
  fi
  printf '\n' >&2
}

# ui::kv LABEL VALUE [COLOR]
ui::kv() {
  local label="$1" value="$2" color="${3:-}"
  printf '  %s%s%s  %s%s%s\n' "$C_GREY" "$(ui::pad "$label" 14)" "$C_RESET" "$color" "$value" "$C_RESET" >&2
}
