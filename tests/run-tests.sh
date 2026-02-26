#!/usr/bin/env bash
#
# Test suite for tmux-start.sh and tmux-list.sh
#
# Tests:
#   1  fresh-run          All windows created on clean slate
#   2  idempotent-skip    Re-run skips all existing windows
#   3  restart-flag       --restart kills and recreates all windows
#   4  restart-single     --restart works for single-window sessions (regression)
#   5  tmux-list          tmux-list.sh shows formatted table
#   6  help-flag          --help prints usage and exits 0
#   7  piped-no-color     Piped output uses [PASS]/[SKIP] text markers
#   8  missing-config     Missing config file errors with exit 1
#   9  unknown-option     Unknown flag errors with exit 1
#  10  multiple-configs   Two positional args errors with exit 1
#  11  short-flag         -r behaves like --restart
#  12  continuations      + lines are sent to newly created windows
#  13  skip-continuations + lines are NOT sent to skipped windows
#  14  partial-session    Missing window is added to existing session
#  15  long-cmd-truncate  Commands >60 chars are truncated with ...
#  16  list-no-server     tmux-list.sh prints message when no server
#  17  workdir            workdir option sends cd to the window
#  18  inline-comments    Inline # comments are stripped from config lines
#
# Requirements: tmux, bash
# Usage: ./tests/run-tests.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
START="$SCRIPT_DIR/tmux-start.sh"
LIST="$SCRIPT_DIR/tmux-list.sh"

# Isolated tmux socket so tests don't interfere with real sessions
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}"/tmux-test.XXXXXXXXXX)
export TMUX_TMPDIR="$TEST_TMPDIR"

PASS=0
FAIL=0
ERRORS=""

# --- Test config files ---
CONF_MAIN="$TEST_TMPDIR/test.conf"
cat > "$CONF_MAIN" <<'EOF'
# Multi-window session with workdir and continuations
[alpha]
workdir = /tmp
- win1 = echo hello-from-win1
+ echo continuation-1
+ echo continuation-2
- win2 = echo hello-from-win2

# Single-window session (no workdir)
[beta]
- single = echo only-window

# Inline comment test
[gamma]
workdir = /tmp
- noted = echo visible   # this comment should be stripped
EOF

CONF_LONG="$TEST_TMPDIR/long.conf"
cat > "$CONF_LONG" <<'EOF'
[longcmd]
- longwin = echo this is a very long command that should be truncated at sixty characters by the log_result function
EOF

# --- Helpers ---
cleanup_tmux() {
    tmux kill-server 2>/dev/null || true
    sleep 0.1
}

# capture stdout+stderr, don't fail on nonzero exit
run() {
    "$@" 2>&1 || true
}

assert_contains() {
    local label="$1" output="$2" pattern="$3"
    if echo "$output" | grep -qF -- "$pattern"; then
        return 0
    else
        ERRORS+="  $label: expected to find '$pattern'\n"
        return 1
    fi
}

assert_not_contains() {
    local label="$1" output="$2" pattern="$3"
    if echo "$output" | grep -qF -- "$pattern"; then
        ERRORS+="  $label: should NOT contain '$pattern'\n"
        return 1
    else
        return 0
    fi
}

assert_exit() {
    local label="$1" expected="$2"
    shift 2
    local actual
    "$@" 2>/dev/null && actual=0 || actual=$?
    if [[ $actual -ne $expected ]]; then
        ERRORS+="  $label: expected exit $expected, got $actual\n"
        return 1
    fi
    return 0
}

run_test() {
    local num="$1" name="$2"
    local ok=1
    ERRORS=""
    # run the test function; if it returns nonzero, mark failed
    if "test_$name"; then
        ok=1
    else
        ok=0
    fi
    # also fail if any assert set ERRORS
    if [[ -n "$ERRORS" ]]; then
        ok=0
    fi
    if [[ $ok -eq 1 ]]; then
        printf "  \e[32m✓\e[0m %2d  %s\n" "$num" "$name"
        PASS=$((PASS + 1))
    else
        printf "  \e[31m✗\e[0m %2d  %s\n" "$num" "$name"
        printf "%b" "$ERRORS"
        FAIL=$((FAIL + 1))
    fi
}

# ─── Test functions ──────────────────────────────────────────

test_fresh_run() {
    cleanup_tmux
    local out
    out=$(run "$START" "$CONF_MAIN")
    assert_contains "alpha/win1" "$out" "[PASS] win1" &&
    assert_contains "alpha/win2" "$out" "[PASS] win2" &&
    assert_contains "beta/single" "$out" "[PASS] single" &&
    assert_contains "gamma/noted" "$out" "[PASS] noted" &&
    # verify tmux state
    tmux list-windows -t alpha -F '#{window_name}' | grep -qx win1 &&
    tmux list-windows -t alpha -F '#{window_name}' | grep -qx win2 &&
    tmux list-windows -t beta -F '#{window_name}' | grep -qx single &&
    tmux list-windows -t gamma -F '#{window_name}' | grep -qx noted
}

test_idempotent_skip() {
    # requires state from fresh_run
    local out
    out=$(run "$START" "$CONF_MAIN")
    assert_contains "win1" "$out" "[SKIP] win1" &&
    assert_contains "win2" "$out" "[SKIP] win2" &&
    assert_contains "single" "$out" "[SKIP] single" &&
    assert_contains "noted" "$out" "[SKIP] noted"
}

test_restart_flag() {
    # requires state from fresh_run
    local out
    out=$(run "$START" --restart "$CONF_MAIN")
    assert_contains "win1" "$out" "[PASS] win1" &&
    assert_contains "win1-reason" "$out" "(restarted)" &&
    assert_contains "win2" "$out" "[PASS] win2"
}

test_restart_single() {
    # single-window sessions must survive restart (regression test)
    local out
    out=$(run "$START" --restart "$CONF_MAIN")
    assert_contains "beta" "$out" "[PASS] single" &&
    assert_contains "beta-reason" "$out" "(restarted)" &&
    assert_contains "gamma" "$out" "[PASS] noted" &&
    assert_not_contains "beta-fail" "$out" "[FAIL] single" &&
    assert_not_contains "gamma-fail" "$out" "[FAIL] noted"
}

test_tmux_list() {
    local out
    out=$(run "$LIST")
    assert_contains "header" "$out" "SESSION" &&
    assert_contains "alpha" "$out" "alpha" &&
    assert_contains "beta" "$out" "beta" &&
    assert_contains "gamma" "$out" "gamma" &&
    assert_contains "active" "$out" "*"
}

test_help_flag() {
    local out
    out=$("$START" --help 2>&1) || true
    assert_contains "usage" "$out" "Usage:" &&
    assert_contains "restart" "$out" "--restart" &&
    assert_contains "help" "$out" "--help"
}

test_piped_no_color() {
    local out
    out=$(run "$START" "$CONF_MAIN" | cat)
    # should use text markers, no escape codes
    assert_contains "marker" "$out" "[SKIP]" &&
    assert_not_contains "escape" "$out" $'\e['
}

test_missing_config() {
    local out
    out=$("$START" /nonexistent/path 2>&1) && return 1 || true
    assert_contains "msg" "$out" "Config not found"
}

test_unknown_option() {
    local out
    out=$("$START" --bogus 2>&1) && return 1 || true
    assert_contains "msg" "$out" "Unknown option"
}

test_multiple_configs() {
    local out
    out=$("$START" file1 file2 2>&1) && return 1 || true
    assert_contains "msg" "$out" "multiple config files"
}

test_short_flag() {
    local out
    out=$(run "$START" -r "$CONF_MAIN")
    assert_contains "restarted" "$out" "(restarted)"
}

test_continuations() {
    cleanup_tmux
    run "$START" "$CONF_MAIN" >/dev/null
    sleep 0.3
    local pane
    pane=$(tmux capture-pane -t alpha:win1 -p 2>&1)
    assert_contains "cont1" "$pane" "continuation-1" &&
    assert_contains "cont2" "$pane" "continuation-2"
}

test_skip_continuations() {
    # run again — windows skipped, continuations should NOT be re-sent
    # capture pane before
    local before after
    before=$(tmux capture-pane -t alpha:win1 -p 2>&1)
    run "$START" "$CONF_MAIN" >/dev/null
    sleep 0.3
    after=$(tmux capture-pane -t alpha:win1 -p 2>&1)
    # pane content should be unchanged
    if [[ "$before" == "$after" ]]; then
        return 0
    else
        ERRORS+="  skip_continuations: pane content changed after skip\n"
        return 1
    fi
}

test_partial_session() {
    # kill one window, re-run — only the missing one should be created
    tmux kill-window -t alpha:win2 2>/dev/null || true
    local out
    out=$(run "$START" "$CONF_MAIN")
    assert_contains "win1-skip" "$out" "[SKIP] win1" &&
    assert_contains "win2-pass" "$out" "[PASS] win2" &&
    # verify both exist now
    tmux list-windows -t alpha -F '#{window_name}' | grep -qx win2
}

test_long_cmd_truncate() {
    cleanup_tmux
    local out
    out=$(run "$START" "$CONF_LONG")
    assert_contains "truncated" "$out" "..." &&
    assert_not_contains "full-cmd" "$out" "log_result function"
}

test_list_no_server() {
    cleanup_tmux
    local out
    out=$(run "$LIST")
    assert_contains "msg" "$out" "No tmux sessions running."
}

test_workdir() {
    cleanup_tmux
    run "$START" "$CONF_MAIN" >/dev/null
    sleep 0.3
    local pane
    pane=$(tmux capture-pane -t alpha:win1 -p 2>&1)
    assert_contains "cd" "$pane" "cd /tmp"
}

test_inline_comments() {
    # gamma's window command should have "echo visible" but not "this comment"
    local pane
    pane=$(tmux capture-pane -t gamma:noted -p 2>&1)
    assert_contains "visible" "$pane" "visible" &&
    assert_not_contains "comment" "$pane" "this comment"
}

# ─── Run ─────────────────────────────────────────────────────

echo ""
echo "tmux-quickstart test suite"
echo "────────────────────────────────────"

# Tests that build on shared state run in order
run_test  1 fresh_run
run_test  2 idempotent_skip
run_test  3 restart_flag
run_test  4 restart_single
run_test  5 tmux_list
run_test  6 help_flag
run_test  7 piped_no_color
run_test  8 missing_config
run_test  9 unknown_option
run_test 10 multiple_configs
run_test 11 short_flag
run_test 12 continuations
run_test 13 skip_continuations
run_test 14 partial_session
run_test 15 long_cmd_truncate
run_test 16 list_no_server
run_test 17 workdir
run_test 18 inline_comments

echo ""
echo "────────────────────────────────────"
echo "  $PASS passed, $FAIL failed"

# Cleanup
cleanup_tmux
rm -rf "$TEST_TMPDIR"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
