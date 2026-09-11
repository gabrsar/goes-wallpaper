#!/usr/bin/env bash
# One-command installer for goes-wallpaper.
#
#   curl -fsSL https://raw.githubusercontent.com/gabrsar/goes-wallpaper/master/install.sh | bash
#
# Installs entirely under $HOME — no sudo, nothing written outside your user
# account. Running it again upgrades an existing installation in place.
#
# Environment overrides:
#   GOES_INSTALL_DIR   where to put the source   (default ~/.local/share/goes-wallpaper)
#   GOES_BIN_DIR       where to put the command  (default ~/.local/bin)
#   GOES_REPO          repository to clone       (default the upstream HTTPS URL)
#   GOES_BRANCH        branch or tag to check out
#   GOES_NO_SETUP=1    install only; skip the configuration wizard
#   GOES_NO_PATH=1     do not touch any shell startup file

set -euo pipefail

GOES_REPO="${GOES_REPO:-https://github.com/gabrsar/goes-wallpaper.git}"
GOES_BRANCH="${GOES_BRANCH:-}"
INSTALL_DIR="${GOES_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/goes-wallpaper}"
BIN_DIR="${GOES_BIN_DIR:-$HOME/.local/bin}"
PATH_MARKER="# added by goes-wallpaper installer"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  R=$'\033[0m'; B=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'
else
  R=''; B=''; DIM=''; RED=''; GRN=''; YLW=''; CYN=''
fi

say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '%s✔%s %s\n' "$GRN" "$R" "$*" >&2; }
info() { printf '%s•%s %s\n' "$CYN" "$R" "$*" >&2; }
warn() { printf '%s▲ %s%s\n' "$YLW" "$*" "$R" >&2; }
die()  { printf '%s✘ %s%s\n' "$RED" "$*" "$R" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

banner() {
  say ""
  say "${B}${CYN}  ◜◝  GOES Wallpaper${R}"
  say "${DIM}  ◟◞  real-time Earth from geostationary orbit${R}"
  say ""
}

# ── Preflight ────────────────────────────────────────────────────────────────
check_platform() {
  case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)  PLATFORM=linux ;;
    *) die "Unsupported platform: $(uname -s). goes-wallpaper runs on macOS and Linux." ;;
  esac
  info "Platform: $PLATFORM"
}

check_dependencies() {
  local missing=''
  have curl || missing="$missing curl"
  have git  || missing="$missing git"
  if [ -n "$missing" ]; then
    say ""
    die "Missing:$missing

Install them first:
  macOS          xcode-select --install
  Debian/Ubuntu  sudo apt install curl git
  Fedora         sudo dnf install curl git
  Arch           sudo pacman -S curl git"
  fi

  local major="${BASH_VERSINFO[0]:-0}"
  [ "$major" -ge 3 ] || die "bash 3.2 or newer is required (found ${BASH_VERSION:-unknown})."
  ok "Dependencies present"
}

# ── Source tree ──────────────────────────────────────────────────────────────
# When the installer is executed from inside a checkout, install that checkout
# rather than cloning a second copy somewhere else.
local_checkout_root() {
  local src="${BASH_SOURCE[0]:-}" dir
  [ -n "$src" ] || return 1
  [ -f "$src" ] || return 1
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  [ -f "$dir/bin/goes" ] || return 1
  [ -f "$dir/lib/common.sh" ] || return 1
  printf '%s' "$dir"
}

fetch_source() {
  local existing
  if existing=$(local_checkout_root); then
    INSTALL_DIR="$existing"
    ok "Using this checkout: $INSTALL_DIR"
    return 0
  fi

  if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing installation at $INSTALL_DIR"
    git -C "$INSTALL_DIR" remote set-url origin "$GOES_REPO" 2>/dev/null || true
    git -C "$INSTALL_DIR" fetch --quiet --depth 1 origin "${GOES_BRANCH:-HEAD}" \
      || die "Could not fetch updates from $GOES_REPO"
    git -C "$INSTALL_DIR" reset --quiet --hard FETCH_HEAD \
      || die "Could not update $INSTALL_DIR"
    ok "Updated to $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
    return 0
  fi

  if [ -e "$INSTALL_DIR" ]; then
    die "$INSTALL_DIR exists but is not a git checkout. Move it aside and re-run."
  fi

  info "Cloning $GOES_REPO"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  if [ -n "$GOES_BRANCH" ]; then
    git clone --quiet --depth 1 --branch "$GOES_BRANCH" "$GOES_REPO" "$INSTALL_DIR" \
      || die "Clone failed. Check the URL and your network."
  else
    git clone --quiet --depth 1 "$GOES_REPO" "$INSTALL_DIR" \
      || die "Clone failed. Check the URL and your network."
  fi
  ok "Cloned to $INSTALL_DIR"
}

# ── Command on PATH ──────────────────────────────────────────────────────────
link_command() {
  chmod +x "$INSTALL_DIR/bin/goes"
  mkdir -p "$BIN_DIR"

  local target="$BIN_DIR/goes"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ -L "$target" ] && [ "$(readlink "$target")" = "$INSTALL_DIR/bin/goes" ]; then
      ok "Command already linked: $target"
      return 0
    fi
    if [ -L "$target" ]; then
      rm -f "$target"
    else
      die "$target already exists and is not a symlink. Move it aside and re-run."
    fi
  fi

  ln -s "$INSTALL_DIR/bin/goes" "$target"
  ok "Linked $target"
}

shell_rc_file() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    zsh)  printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash)
      # On macOS, login shells read .bash_profile and often never read .bashrc.
      if [ "$PLATFORM" = "macos" ] && [ -f "$HOME/.bash_profile" ]; then
        printf '%s' "$HOME/.bash_profile"
      else
        printf '%s' "$HOME/.bashrc"
      fi ;;
    fish) printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
    *)    printf '%s' "$HOME/.profile" ;;
  esac
}

ensure_on_path() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ok "$BIN_DIR is already on your PATH"; return 0 ;;
  esac

  if [ -n "${GOES_NO_PATH:-}" ]; then
    warn "$BIN_DIR is not on your PATH; add it yourself to use the 'goes' command."
    return 0
  fi

  local rc; rc="$(shell_rc_file)"
  if [ -f "$rc" ] && grep -qF "$PATH_MARKER" "$rc" 2>/dev/null; then
    warn "$rc already has the PATH entry; open a new terminal to pick it up."
    return 0
  fi

  mkdir -p "$(dirname "$rc")"
  case "$rc" in
    *fish/config.fish)
      {
        printf '\n%s\n' "$PATH_MARKER"
        printf 'fish_add_path %s\n' "$BIN_DIR"
      } >>"$rc" ;;
    *)
      {
        printf '\n%s\n' "$PATH_MARKER"
        printf 'export PATH="$PATH:%s"\n' "$BIN_DIR"
      } >>"$rc" ;;
  esac
  export PATH="$PATH:$BIN_DIR"
  ok "Added $BIN_DIR to your PATH in $rc"
  PATH_NEEDS_RELOAD="$rc"
}

# Another `goes` earlier on PATH (a v1 symlink in /usr/local/bin, say) would
# silently win over the one just installed.
check_shadowing() {
  local found
  found=$(command -v goes 2>/dev/null) || return 0
  [ "$found" = "$BIN_DIR/goes" ] && return 0
  if [ -L "$found" ] && [ "$(readlink "$found")" = "$INSTALL_DIR/bin/goes" ]; then
    return 0
  fi
  warn "Another 'goes' comes first on your PATH: $found"
  if [ -L "$found" ] && [ ! -e "$found" ]; then
    say "  It is a broken link left by an older install. Remove it with:"
  else
    say "  Remove it, or put $BIN_DIR earlier on your PATH:"
  fi
  if [ -w "$(dirname "$found")" ]; then
    say "    rm '$found'"
  else
    say "    sudo rm '$found'"
  fi
}

# ── Wizard ───────────────────────────────────────────────────────────────────
# stdin is the curl pipe when installing the documented way, so hand the wizard
# the real terminal.
run_setup() {
  if [ -n "${GOES_NO_SETUP:-}" ]; then
    info "Skipping configuration (GOES_NO_SETUP is set)."
    return 0
  fi
  # `-r /dev/tty` is true even with no controlling terminal; only opening it
  # tells the truth.
  if ! ( exec </dev/tty ) 2>/dev/null; then
    warn "No terminal available; skipping configuration."
    say ""
    say "  Finish the install with:  ${B}goes setup${R}"
    return 0
  fi
  say ""
  "$INSTALL_DIR/bin/goes" setup </dev/tty || return $?
}

final_message() {
  say ""
  say "${B}Installed.${R}"
  say ""
  say "  ${B}goes${R}           what is configured and running"
  say "  ${B}goes setup${R}     change region, size or refresh rate"
  say "  ${B}goes doctor${R}    check everything end to end"
  say "  ${B}goes help${R}      all commands"
  say ""
  if [ -n "${PATH_NEEDS_RELOAD:-}" ]; then
    say "  ${YLW}Open a new terminal${R} (or run ${B}source $PATH_NEEDS_RELOAD${R}) to use the 'goes' command."
    say ""
  fi
}

main() {
  banner
  check_platform
  check_dependencies
  fetch_source
  link_command
  ensure_on_path
  check_shadowing
  if ! run_setup; then
    warn "Setup did not finish. Run 'goes setup' whenever you are ready."
  fi
  final_message
}

PATH_NEEDS_RELOAD=''
main "$@"
