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

run_ensure() {
  HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" \
    PATH="$TEST_BIN:$PATH" AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=macos \
    AMP_RUNNER_TEST_SENTINEL="$TEST_SENTINEL" AMP_RUNNER_AMP_BIN="$FAKE_AMP" \
    "$CLI" ensure "$1" --repo "$2"
}

printf '1..34\n'

help_output=$("$CLI" --help 2>&1)
assert_contains "help lists ensure's exact argument order" "$help_output" "amp-runner ensure <directory> --repo <git-url>"
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
TEST_SENTINEL="$TEST_ROOT/service-or-amp-ran"
mkdir -p "$PROJECT" "$OUTSIDE" "$(dirname "$FAKE_AMP")" "$TEST_CONFIG/amp-runner" "$TEST_BIN"
printf '#!/bin/sh\n[ -z "${AMP_RUNNER_TEST_SENTINEL:-}" ] || touch "$AMP_RUNNER_TEST_SENTINEL"\nexit 0\n' > "$FAKE_AMP"
chmod 700 "$FAKE_AMP"
printf '#!/bin/sh\nexit 0\n' > "$TEST_BIN/plutil"
printf '#!/bin/sh\n[ -z "${AMP_RUNNER_TEST_SENTINEL:-}" ] || touch "$AMP_RUNNER_TEST_SENTINEL"\nexit 97\n' > "$TEST_BIN/launchctl"
chmod 700 "$TEST_BIN/plutil" "$TEST_BIN/launchctl"
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

REMOTE_ONE="$TEST_ROOT/remote-one.git"
REMOTE_TWO="$TEST_ROOT/remote-two.git"
git init -q --bare "$REMOTE_ONE"
git init -q --bare "$REMOTE_TWO"

ENSURE_ABSENT="$ALLOWED/ensured absent"
ensure_absent_output=$(run_ensure "$ENSURE_ABSENT" "$REMOTE_ONE" 2>&1)
if [ -d "$ENSURE_ABSENT/.git" ] \
  && [ "$(git -C "$ENSURE_ABSENT" config --get remote.origin.url)" = "$REMOTE_ONE" ]; then
  assert_contains "ensure clones an absent destination" "$ensure_absent_output" \
    "Cloned $REMOTE_ONE into $CANONICAL_ALLOWED/ensured absent"
else
  fail "ensure clones an absent destination"
fi

ensure_repeat_output=$(run_ensure "$ENSURE_ABSENT" "$REMOTE_ONE///" 2>&1)
assert_contains "ensure is idempotent and applies only documented URL normalisation" \
  "$ensure_repeat_output" "Verified existing checkout at $CANONICAL_ALLOWED/ensured absent"

ENSURE_EXISTING="$ALLOWED/matching existing checkout"
git clone -q -- "$REMOTE_ONE" "$ENSURE_EXISTING" 2>/dev/null
ensure_existing_output=$(run_ensure "$ENSURE_EXISTING" "$REMOTE_ONE" 2>&1)
assert_contains "ensure accepts a matching existing checkout" \
  "$ensure_existing_output" "Verified existing checkout at $CANONICAL_ALLOWED/matching existing checkout"

ENSURE_MISMATCH="$ALLOWED/mismatched checkout"
git clone -q -- "$REMOTE_ONE" "$ENSURE_MISMATCH" 2>/dev/null
if run_ensure "$ENSURE_MISMATCH" "$REMOTE_TWO" >"$TEST_ROOT/mismatch.out" 2>&1; then
  fail "ensure refuses a mismatched origin without changing it"
elif case $(cat "$TEST_ROOT/mismatch.out") in
    *"repository URL mismatch"*"expected: $REMOTE_TWO"*"actual:   $REMOTE_ONE"*) true ;;
    *) false ;;
  esac \
  && [ "$(git -C "$ENSURE_MISMATCH" config --get remote.origin.url)" = "$REMOTE_ONE" ]; then
  pass "ensure refuses a mismatched origin without changing it"
else
  fail "ensure refuses a mismatched origin without changing it"
fi

ENSURE_UNRELATED="$ALLOWED/unrelated nonempty"
mkdir "$ENSURE_UNRELATED"
printf 'keep\n' > "$ENSURE_UNRELATED/content.txt"
if run_ensure "$ENSURE_UNRELATED" "$REMOTE_ONE" >"$TEST_ROOT/unrelated.out" 2>&1; then
  fail "ensure refuses and preserves an unrelated nonempty directory"
elif [ "$(cat "$ENSURE_UNRELATED/content.txt")" = keep ]; then
  assert_contains "ensure refuses and preserves an unrelated nonempty directory" \
    "$(cat "$TEST_ROOT/unrelated.out")" "not a Git worktree root"
else
  fail "ensure refuses and preserves an unrelated nonempty directory"
fi

ENSURE_EMPTY="$ALLOWED/existing empty"
mkdir "$ENSURE_EMPTY"
ensure_empty_output=$(run_ensure "$ENSURE_EMPTY" "$REMOTE_ONE" 2>&1)
if [ -d "$ENSURE_EMPTY/.git" ]; then
  assert_contains "ensure supports an existing empty destination" \
    "$ensure_empty_output" "Cloned $REMOTE_ONE into $CANONICAL_ALLOWED/existing empty"
else
  fail "ensure supports an existing empty destination"
fi

ENSURE_OUTSIDE="$OUTSIDE/outside clone"
if run_ensure "$ENSURE_OUTSIDE" "$REMOTE_ONE" >"$TEST_ROOT/outside-ensure.out" 2>&1; then
  fail "ensure refuses a path outside allowed roots"
elif [ ! -e "$ENSURE_OUTSIDE" ]; then
  assert_contains "ensure refuses a path outside allowed roots" \
    "$(cat "$TEST_ROOT/outside-ensure.out")" "outside the configured allowed roots"
else
  fail "ensure refuses a path outside allowed roots"
fi

ENSURE_SYMLINK="$ALLOWED/symlink destination"
ln -s "$PROJECT" "$ENSURE_SYMLINK"
if run_ensure "$ENSURE_SYMLINK" "$REMOTE_ONE" >"$TEST_ROOT/symlink-ensure.out" 2>&1; then
  fail "ensure refuses a symlink destination"
elif [ -L "$ENSURE_SYMLINK" ]; then
  assert_contains "ensure refuses a symlink destination" \
    "$(cat "$TEST_ROOT/symlink-ensure.out")" "must not be a symbolic link"
else
  fail "ensure refuses a symlink destination"
fi

if [ ! -e "$TEST_SENTINEL" ]; then
  pass "ensure test mode does not run Amp or a service manager"
else
  fail "ensure test mode does not run Amp or a service manager"
fi

if HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" \
    AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=macos "$CLI" \
    ensure --repo "$REMOTE_ONE" "$ENSURE_ABSENT" >"$TEST_ROOT/order.out" 2>&1 \
  || HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" \
    AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=macos "$CLI" \
    ensure "$ENSURE_ABSENT" --repo "$REMOTE_ONE" extra >>"$TEST_ROOT/order.out" 2>&1 \
  || HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_CONFIG" XDG_STATE_HOME="$TEST_STATE" \
    AMP_RUNNER_TEST_MODE=1 AMP_RUNNER_TEST_PLATFORM=macos "$CLI" \
    ensure "$ENSURE_ABSENT" --repo >>"$TEST_ROOT/order.out" 2>&1; then
  fail "ensure rejects missing, reordered, and extra arguments"
else
  assert_contains "ensure rejects missing, reordered, and extra arguments" \
    "$(cat "$TEST_ROOT/order.out")" "ensure <directory> --repo <git-url>"
fi

if run_ensure "$ALLOWED/invalid repo" "-bad" >"$TEST_ROOT/unsafe-input.out" 2>&1 \
  || run_ensure "$ALLOWED/invalid repo" "" >>"$TEST_ROOT/unsafe-input.out" 2>&1 \
  || run_ensure "$ALLOWED/invalid repo" $'bad\nrepo' >>"$TEST_ROOT/unsafe-input.out" 2>&1 \
  || run_ensure "$ALLOWED/invalid repo" $'bad\rrepo' >>"$TEST_ROOT/unsafe-input.out" 2>&1 \
  || run_ensure $'bad\ndirectory' "$REMOTE_ONE" >>"$TEST_ROOT/unsafe-input.out" 2>&1; then
  fail "ensure rejects unsafe repository and directory values"
else
  assert_contains "ensure rejects unsafe repository and directory values" \
    "$(cat "$TEST_ROOT/unsafe-input.out")" "repository URL must not begin with -"
fi

ENSURE_FAILED="$ALLOWED/failed clone"
if run_ensure "$ENSURE_FAILED" "$TEST_ROOT/does-not-exist.git" >"$TEST_ROOT/clone-failure.out" 2>&1; then
  fail "clone failure leaves no destination or sibling temporary path"
else
  clone_temp_left=0
  for clone_temp in "$ALLOWED"/.amp-runner-ensure.*; do
    [ -e "$clone_temp" ] && clone_temp_left=1
  done
  if [ ! -e "$ENSURE_FAILED" ] && [ "$clone_temp_left" -eq 0 ]; then
    pass "clone failure leaves no destination or sibling temporary path"
  else
    fail "clone failure leaves no destination or sibling temporary path"
  fi
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
