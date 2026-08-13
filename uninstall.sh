#!/bin/bash

set -u

PROGRAM_NAME=uninstall.sh
SCRIPT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) \
  || { printf 'uninstall.sh: cannot locate the source directory\n' >&2; exit 1; }
INSTALL_ROOT=${PREFIX:-"$HOME/.local"}
INSTALL_PATH="$INSTALL_ROOT/bin/amp-runner"
CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}/amp-runner
RUNNER=$INSTALL_PATH
FORCE=0

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--force]

Refuses to uninstall while managed runners are active. --force stops only
services recorded in amp-runner's private metadata. Amp itself is untouched.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit 1
}

reject_line_breaks() {
  case $1 in *$'\n'*|*$'\r'*) die "$2 contains a carriage return or newline" ;; esac
}

remove_file() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  if [ "$(uname -s)" = Darwin ] && command -v trash >/dev/null 2>&1; then
    trash "$1"
  else
    unlink "$1"
  fi
}

remove_tree() {
  local target=$1
  [ -e "$target" ] || return 0
  reject_line_breaks "$target" "removal path"
  case $target in ''|/|"$HOME") die "refusing unsafe removal path: $target" ;; esac
  if [ "$(uname -s)" = Darwin ] && command -v trash >/dev/null 2>&1; then
    trash "$target"
  else
    rm -rf -- "$target"
  fi
}

clean_empty_state() {
  local state_root logs_root locks projects units logs
  case $(uname -s) in
    Darwin)
      state_root="$HOME/Library/Application Support/AmpRunners"
      logs_root="$HOME/Library/Logs/AmpRunners"
      locks="$state_root/locks"
      projects="$state_root/projects"
      remove_file "$locks/global.lock" || true
      rmdir "$projects" "$locks" "$state_root" "$logs_root" 2>/dev/null || true
      ;;
    Linux)
      state_root="${XDG_STATE_HOME:-$HOME/.local/state}/amp-runner"
      locks="$state_root/locks"
      projects="$state_root/projects"
      units="$state_root/systemd"
      logs="$state_root/logs"
      remove_file "$locks/global.lock" || true
      rmdir "$projects" "$units" "$logs" "$locks" "$state_root" 2>/dev/null || true
      ;;
    *) die "unsupported platform (macOS and Linux are supported)" ;;
  esac
}

main() {
  local uninstall_output uninstall_status=0
  umask 077
  while [ "$#" -gt 0 ]; do
    case $1 in
      --force) FORCE=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  reject_line_breaks "$HOME" HOME
  reject_line_breaks "$INSTALL_ROOT" PREFIX
  reject_line_breaks "$CONFIG_ROOT" "config path"
  if [ ! -x "$RUNNER" ]; then
    RUNNER="$SCRIPT_DIR/amp-runner"
  fi
  [ -x "$RUNNER" ] || die "cannot find an executable amp-runner for managed-service checks"

  uninstall_output=$(AMP_RUNNER_UNINSTALL=1 "$RUNNER" __uninstall "$FORCE" 2>&1) || uninstall_status=$?
  if [ "$uninstall_status" -eq 3 ]; then
    printf '%s\n' "$uninstall_output" >&2
    die "managed runners are active; stop them first or use --force"
  fi
  if [ "$uninstall_status" -ne 0 ]; then
    printf '%s\n' "$uninstall_output" >&2
    die "could not inspect or remove managed services; installation was kept"
  fi
  [ -z "$uninstall_output" ] || printf '%s\n' "$uninstall_output"
  remove_file "$INSTALL_PATH" || die "cannot remove $INSTALL_PATH"
  clean_empty_state
  remove_tree "$CONFIG_ROOT"
  printf 'Uninstalled amp-runner. Amp itself was not changed.\n'
}

main "$@"
