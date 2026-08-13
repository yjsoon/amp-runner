#!/bin/bash

set -u

ROOT_DIR=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd -P) \
  || { printf 'cannot locate repository root\n' >&2; exit 1; }
CLI="$ROOT_DIR/amp-runner"
INSTALLER="$ROOT_DIR/install.sh"
UNINSTALLER="$ROOT_DIR/uninstall.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/amp-runner-tests.XXXXXX") || exit 1
TESTS=0
FAILURES=0

cleanup() {
  if command -v trash >/dev/null 2>&1; then
    trash "$TEST_ROOT" >/dev/null 2>&1 || true
  else
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

pass() {
  TESTS=$((TESTS + 1))
  printf 'ok %d - %s\n' "$TESTS" "$1"
}

fail() {
  TESTS=$((TESTS + 1))
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$TESTS" "$1"
}

assert_contains() {
  local description=$1 haystack=$2 needle=$3
  case $haystack in *"$needle"*) pass "$description" ;; *) fail "$description" ;; esac
}

assert_equal() {
  local description=$1 actual=$2 expected=$3
  if [ "$actual" = "$expected" ]; then pass "$description"; else fail "$description"; fi
}

mode_of() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

run_debug() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" \
    AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=macos \
    AMP_RUNNER_AMP_BIN="$FAKE_AMP" "$CLI" debug "$1"
}

printf '1..21\n'

help_output=$("$CLI" --help 2>&1)
assert_contains "help lists start" "$help_output" "amp-runner start [directory]"
assert_contains "help lists follow logs" "$help_output" "logs [-f|--follow] [directory]"

TEST_HOME="$TEST_ROOT/home"
TEST_CONFIG="$TEST_ROOT/config"
TEST_STATE="$TEST_ROOT/state"
ALLOWED="$TEST_HOME/Allowed Projects"
PROJECT="$ALLOWED/project alpha"
OUTSIDE="$TEST_HOME/outside"
FAKE_AMP="$TEST_HOME/.amp/bin/amp"
TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$PROJECT" "$OUTSIDE" "$(dirname "$FAKE_AMP")" "$TEST_CONFIG/amp-runner" "$TEST_BIN"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_AMP"
chmod 700 "$FAKE_AMP"
printf '#!/bin/sh\nexit 0\n' > "$TEST_BIN/plutil"
chmod 700 "$TEST_BIN/plutil"
printf '%s\n' "$ALLOWED" > "$TEST_CONFIG/amp-runner/allowed-roots"
chmod 700 "$TEST_CONFIG/amp-runner"
chmod 600 "$TEST_CONFIG/amp-runner/allowed-roots"
CANONICAL_ALLOWED=$(unset CDPATH; cd -- "$ALLOWED" && pwd -P)
CANONICAL_PROJECT=$(unset CDPATH; cd -- "$PROJECT" && pwd -P)

debug_real=$(run_debug "$PROJECT")
assert_contains "allowed descendant is accepted" "$debug_real" "project_path=$CANONICAL_PROJECT"
debug_root=$(run_debug "$ALLOWED")
assert_contains "exact allowed root is accepted" "$debug_root" "project_path=$CANONICAL_ALLOWED"

if run_debug "$OUTSIDE" >"$TEST_ROOT/reject.out" 2>&1; then
  fail "outside root is rejected"
else
  assert_contains "outside root is rejected" "$(cat "$TEST_ROOT/reject.out")" "outside the configured allowed roots"
fi

ln -s "$PROJECT" "$TEST_HOME/project-link"
debug_link=$(run_debug "$TEST_HOME/project-link")
real_path=$(printf '%s\n' "$debug_real" | sed -n 's/^project_path=//p')
link_path=$(printf '%s\n' "$debug_link" | sed -n 's/^project_path=//p')
assert_equal "symlink uses canonical project identity" "$link_path" "$real_path"

real_hash=$(printf '%s\n' "$debug_real" | sed -n 's/^project_hash=//p')
link_hash=$(printf '%s\n' "$debug_link" | sed -n 's/^project_hash=//p')
assert_equal "canonical identity has deterministic SHA-256" "$link_hash" "$real_hash"

real_id=$(printf '%s\n' "$debug_real" | sed -n 's/^runner_id=//p')
link_id=$(printf '%s\n' "$debug_link" | sed -n 's/^runner_id=//p')
assert_equal "runner ID is deterministic" "$link_id" "$real_id"
if [ "${#real_id}" -le 63 ] && [ "${real_id##*-}" = "${real_hash:0:12}" ]; then
  pass "runner ID is bounded and ends in 12 hash characters"
else
  fail "runner ID is bounded and ends in 12 hash characters"
fi

service_name=$(printf '%s\n' "$debug_real" | sed -n 's/^service_name=//p')
assert_equal "launchd metadata uses public namespace" "$service_name" "com.yjsoon.amp-runner.$real_hash"

linux_debug=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" \
  AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=linux \
  AMP_RUNNER_AMP_BIN="$FAKE_AMP" "$CLI" debug "$PROJECT")
linux_service=$(printf '%s\n' "$linux_debug" | sed -n 's/^service_name=//p')
assert_equal "Linux metadata uses a direct per-hash systemd unit" "$linux_service" "amp-runner-$real_hash.service"

mac_service_file=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" PATH="$TEST_BIN:$PATH" \
  AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=macos \
  AMP_RUNNER_AMP_BIN="$FAKE_AMP" "$CLI" debug-service "$PROJECT")
mac_service_text=$(cat "$mac_service_file")
assert_contains "generated launchd service has launch and restart behaviour" "$mac_service_text" "<key>RunAtLoad</key>"
if [ "$(mode_of "$mac_service_file")" = 600 ]; then
  pass "generated launchd service is private"
else
  fail "generated launchd service is private"
fi

linux_service_file=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" \
  AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=linux \
  AMP_RUNNER_AMP_BIN="$FAKE_AMP" "$CLI" debug-service "$PROJECT")
linux_service_text=$(cat "$linux_service_file")
escaped_project=$(printf '%s' "$CANONICAL_PROJECT" | sed 's/ /\\x20/g')
if case $linux_service_text in *"WorkingDirectory=$escaped_project"*"Restart=always"*"RestartSec=10"*"StandardOutput=append:"*) true ;; *) false ;; esac; then
  pass "generated systemd service has working directory, restart, and append logs"
else
  fail "generated systemd service has working directory, restart, and append logs"
fi
assert_contains "generated systemd service launches through a clean environment" "$linux_service_text" "ExecStart=/usr/bin/env -i"
if grep -q 'remove_service_file' <(sed -n '/^stop_runner()/,/^}/p' "$CLI"); then
  fail "stop retains service definitions and metadata for restart, list, and uninstall"
else
  pass "stop retains service definitions and metadata for restart, list, and uninstall"
fi

INSTALL_HOME="$TEST_ROOT/install-home"
INSTALL_PREFIX="$TEST_ROOT/prefix"
INSTALL_AMP="$INSTALL_HOME/.amp/bin/amp"
mkdir -p "$INSTALL_HOME/Developer" "$(dirname "$INSTALL_AMP")"
printf '#!/bin/sh\nexit 0\n' > "$INSTALL_AMP"
chmod 700 "$INSTALL_AMP"
HOME="$INSTALL_HOME" PREFIX="$INSTALL_PREFIX" "$INSTALLER" > "$TEST_ROOT/install-1.out"
installed_cli="$INSTALL_PREFIX/bin/amp-runner"
installed_config="$INSTALL_HOME/.config/amp-runner/allowed-roots"
if [ -x "$installed_cli" ] && [ "$(mode_of "$installed_cli")" = 700 ] \
  && [ "$(mode_of "$installed_config")" = 600 ] \
  && [ "$(mode_of "$(dirname "$installed_config")")" = 700 ]; then
  pass "installer creates private CLI and configuration"
else
  fail "installer creates private CLI and configuration"
fi

printf '# preserved configuration\n%s\n' "$INSTALL_HOME/Developer" > "$installed_config"
before=$(sha256_file "$installed_config")
HOME="$INSTALL_HOME" PREFIX="$INSTALL_PREFIX" "$INSTALLER" > "$TEST_ROOT/install-2.out"
after=$(sha256_file "$installed_config")
assert_equal "installer is idempotent and preserves existing config" "$after" "$before"

NEW_ROOT="$INSTALL_HOME/Another Root"
mkdir -p "$NEW_ROOT"
CANONICAL_NEW_ROOT=$(unset CDPATH; cd -- "$NEW_ROOT" && pwd -P)
HOME="$INSTALL_HOME" PREFIX="$INSTALL_PREFIX" "$INSTALLER" \
  --allowed-root "$NEW_ROOT" --allowed-root "$NEW_ROOT" > "$TEST_ROOT/install-3.out"
assert_equal "explicit roots replace config canonically without duplicates" "$(cat "$installed_config")" "$CANONICAL_NEW_ROOT"

FAKE_MANAGER_DIR="$TEST_ROOT/fake-manager"
mkdir -p "$FAKE_MANAGER_DIR"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_MANAGER_DIR/launchctl"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_MANAGER_DIR/systemctl"
chmod 700 "$FAKE_MANAGER_DIR/launchctl" "$FAKE_MANAGER_DIR/systemctl"
HOME="$INSTALL_HOME" PREFIX="$INSTALL_PREFIX" PATH="$FAKE_MANAGER_DIR:$PATH" \
  "$UNINSTALLER" > "$TEST_ROOT/uninstall-1.out"
if [ ! -e "$installed_cli" ] && [ ! -e "$installed_config" ] && [ -x "$INSTALL_AMP" ]; then
  pass "uninstaller removes amp-runner data but leaves Amp untouched"
else
  fail "uninstaller removes amp-runner data but leaves Amp untouched"
fi

if HOME="$INSTALL_HOME" PREFIX="$INSTALL_PREFIX" PATH="$FAKE_MANAGER_DIR:$PATH" \
  "$UNINSTALLER" > "$TEST_ROOT/uninstall-2.out"; then
  pass "uninstaller is idempotent"
else
  fail "uninstaller is idempotent"
fi

if [ "$FAILURES" -eq 0 ]; then
  printf '# all %d tests passed\n' "$TESTS"
  exit 0
fi
printf '# %d of %d tests failed\n' "$FAILURES" "$TESTS" >&2
exit 1
