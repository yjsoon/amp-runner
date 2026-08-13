#!/bin/bash

set -u

PROGRAM_NAME=install.sh
SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) \
  || { printf 'install.sh: cannot locate the source directory\n' >&2; exit 1; }
SOURCE="$SCRIPT_DIR/amp-runner"
INSTALL_ROOT=${PREFIX:-"$HOME/.local"}
INSTALL_DIR="$INSTALL_ROOT/bin"
INSTALL_PATH="$INSTALL_DIR/amp-runner"
CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}/amp-runner
ALLOWED_ROOTS_FILE="$CONFIG_ROOT/allowed-roots"
AMP_BIN=${AMP_RUNNER_AMP_BIN:-"$HOME/.amp/bin/amp"}
ALLOWED_ROOTS=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [--allowed-root DIR]...

Installs amp-runner to ${PREFIX:-$HOME/.local}/bin/amp-runner.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

reject_line_breaks() {
  case $1 in *$'\n'*|*$'\r'*) die "$2 contains a carriage return or newline" ;; esac
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

canonicalise_directory() {
  local directory=$1 output
  [ -d "$directory" ] || die "allowed root is not a directory: $directory"
  output=$(unset CDPATH; cd -- "$directory" 2>/dev/null && { pwd -P; printf '\034'; }) \
    || die "cannot access allowed root: $directory"
  CANONICAL_DIRECTORY=${output%$'\034'}
  CANONICAL_DIRECTORY=${CANONICAL_DIRECTORY%$'\n'}
  reject_line_breaks "$CANONICAL_DIRECTORY" "allowed root"
  case $CANONICAL_DIRECTORY in /*) ;; *) die "allowed root must be absolute: $CANONICAL_DIRECTORY" ;; esac
}

check_prerequisites() {
  local tool
  [ -f "$SOURCE" ] || die "amp-runner source not found: $SOURCE"
  reject_line_breaks "$HOME" HOME
  reject_line_breaks "$INSTALL_ROOT" PREFIX
  reject_line_breaks "$CONFIG_ROOT" "config path"
  reject_line_breaks "$AMP_BIN" "Amp executable path"
  [ -x "$AMP_BIN" ] || die "Amp executable is not executable: $AMP_BIN"
  for tool in awk basename chmod cp dirname hostname id mkdir mv sed tail touch tr uname unlink; do
    need_command "$tool"
  done
  case $(uname -s) in
    Darwin)
      for tool in launchctl lockf lsof plutil shasum; do need_command "$tool"; done
      ;;
    Linux)
      for tool in flock readlink sha256sum systemctl; do need_command "$tool"; done
      ;;
    *) die "unsupported platform (macOS and Linux are supported)" ;;
  esac
}

check_config_location() {
  [ ! -L "$CONFIG_ROOT" ] || die "config directory must not be a symbolic link: $CONFIG_ROOT"
  if [ -e "$ALLOWED_ROOTS_FILE" ] || [ -L "$ALLOWED_ROOTS_FILE" ]; then
    [ -f "$ALLOWED_ROOTS_FILE" ] && [ ! -L "$ALLOWED_ROOTS_FILE" ] \
      || die "existing allowed-roots config must be a regular file"
  fi
}

add_allowed_root() {
  local candidate=$1 existing
  reject_line_breaks "$candidate" "allowed root"
  canonicalise_directory "$candidate"
  if [ "${#ALLOWED_ROOTS[@]}" -gt 0 ]; then
    for existing in "${ALLOWED_ROOTS[@]}"; do
      [ "$existing" = "$CANONICAL_DIRECTORY" ] && return 0
    done
  fi
  ALLOWED_ROOTS+=("$CANONICAL_DIRECTORY")
}

write_allowed_roots() {
  local temporary root
  mkdir -p "$CONFIG_ROOT" || die "cannot create $CONFIG_ROOT"
  chmod 700 "$CONFIG_ROOT" || die "cannot secure $CONFIG_ROOT"
  temporary="$CONFIG_ROOT/.allowed-roots.tmp.$$"
  : > "$temporary" || die "cannot write $temporary"
  for root in "${ALLOWED_ROOTS[@]}"; do
    printf '%s\n' "$root" >> "$temporary" || die "cannot write $temporary"
  done
  chmod 600 "$temporary" || die "cannot secure $temporary"
  mv -f "$temporary" "$ALLOWED_ROOTS_FILE" || die "cannot install $ALLOWED_ROOTS_FILE"
}

install_cli() {
  local temporary
  mkdir -p "$INSTALL_DIR" || die "cannot create $INSTALL_DIR"
  temporary="$INSTALL_DIR/.amp-runner.tmp.$$"
  cp "$SOURCE" "$temporary" || die "cannot copy amp-runner"
  chmod 700 "$temporary" || die "cannot secure installed CLI"
  mv -f "$temporary" "$INSTALL_PATH" || die "cannot install $INSTALL_PATH"
}

main() {
  local supplied=0
  umask 077
  while [ "$#" -gt 0 ]; do
    case $1 in
      --allowed-root)
        [ "$#" -ge 2 ] || die "--allowed-root requires a directory"
        supplied=1
        add_allowed_root "$2"
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  check_prerequisites
  check_config_location

  if [ "$supplied" -eq 1 ]; then
    write_allowed_roots
  elif [ -f "$ALLOWED_ROOTS_FILE" ]; then
    chmod 600 "$ALLOWED_ROOTS_FILE" || die "cannot secure $ALLOWED_ROOTS_FILE"
    chmod 700 "$CONFIG_ROOT" || die "cannot secure $CONFIG_ROOT"
  else
    add_allowed_root "$HOME/Developer"
    write_allowed_roots
  fi
  install_cli

  printf 'Installed amp-runner at %s\n' "$INSTALL_PATH"
  printf 'Allowed roots: %s\n' "$ALLOWED_ROOTS_FILE"
  printf 'No Amp runners were started.\n'
}

main "$@"
