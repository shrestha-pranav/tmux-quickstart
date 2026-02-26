#!/usr/bin/env bash
set -euo pipefail

# --- Color setup ---
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    BOLD=$(tput bold)
    GREEN=$(tput setaf 2)
    RED=$(tput setaf 1)
    YELLOW=$(tput setaf 3)
    CYAN=$(tput setaf 6)
    RESET=$(tput sgr0)
    CHECKMARK="${GREEN}✓${RESET}"
    CROSSMARK="${RED}✗${RESET}"
    SKIPMARK="${YELLOW}⊘${RESET}"
else
    BOLD="" GREEN="" RED="" YELLOW="" CYAN="" RESET=""
    CHECKMARK="[PASS]"
    CROSSMARK="[FAIL]"
    SKIPMARK="[SKIP]"
fi

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [config-file]

Options:
  -r, --restart   Kill and recreate windows that already exist
  -h, --help      Show this help message

Arguments:
  config-file     Path to session config (default: ./sessions.conf)
EOF
    exit 0
}

# --- Argument parsing ---
RESTART=0
CONFIG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--restart) RESTART=1; shift ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -n "$CONFIG" ]]; then
                echo "Error: multiple config files specified" >&2
                exit 1
            fi
            CONFIG="$1"; shift
            ;;
    esac
done

CONFIG="${CONFIG:-./sessions.conf}"

if [[ ! -f "$CONFIG" ]]; then
    echo "Config not found: $CONFIG" >&2
    exit 1
fi

# --- Logging ---
log_result() {
    local name="$1"
    local cmd="$2"
    local status="$3"
    local reason="${4:-}"

    # Truncate long commands
    local display_cmd="$cmd"
    if [[ ${#display_cmd} -gt 60 ]]; then
        display_cmd="${display_cmd:0:57}..."
    fi

    local marker
    case "$status" in
        pass) marker="$CHECKMARK" ;;
        fail) marker="$CROSSMARK" ;;
        skip) marker="$SKIPMARK" ;;
    esac

    local suffix=""
    if [[ -n "$reason" ]]; then
        suffix=" ${YELLOW}(${reason})${RESET}"
    fi

    printf "  %s %-20s %s%s\n" "$marker" "$name" "$display_cmd" "$suffix"
}

# --- State ---
session=""
workdir=""
window_count=0
last_window=""
last_window_skipped=0

flush_session() {
    if [[ -n "$session" && $window_count -eq 0 ]]; then
        echo "Warning: session [$session] has no windows, skipping"
    fi
    session=""
    workdir=""
    window_count=0
    last_window=""
    last_window_skipped=0
}

# --- Window creation (4-case decision matrix) ---
create_window() {
    local name="$1"
    local cmd="$2"
    local session_exists=0
    local window_exists=0

    if tmux has-session -t "$session" 2>/dev/null; then
        session_exists=1
        if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -qx "$name"; then
            window_exists=1
        fi
    fi

    # Case 1: Session doesn't exist — create session with first window
    if [[ $session_exists -eq 0 ]]; then
        if tmux new-session -d -s "$session" -n "$name" 2>/dev/null; then
            log_result "$name" "$cmd" pass
        else
            log_result "$name" "$cmd" fail "session create failed"
            last_window_skipped=1
            return
        fi
    # Case 2: Session exists, window doesn't — add window
    elif [[ $window_exists -eq 0 ]]; then
        # new-window may print "no current client" and return 1 when
        # detached, yet still create the window — verify by checking
        # list-windows after the attempt.
        tmux new-window -t "$session" -n "$name" 2>/dev/null || true
        if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -qx "$name"; then
            log_result "$name" "$cmd" pass
        else
            log_result "$name" "$cmd" fail "window create failed"
            last_window_skipped=1
            return
        fi
    # Case 3: Both exist, no --restart — skip
    elif [[ $RESTART -eq 0 ]]; then
        log_result "$name" "$cmd" skip "already exists"
        last_window_skipped=1
        window_count=$((window_count + 1))
        last_window="$name"
        return
    # Case 4: Both exist, --restart — kill and recreate
    else
        tmux kill-window -t "$session:$name" 2>/dev/null || true
        # Killing the last window destroys the session — fall back to new-session
        if tmux has-session -t "$session" 2>/dev/null; then
            tmux new-window -t "$session" -n "$name" 2>/dev/null || true
        else
            tmux new-session -d -s "$session" -n "$name" 2>/dev/null || true
        fi
        if tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | grep -qx "$name"; then
            log_result "$name" "$cmd" pass "restarted"
        else
            log_result "$name" "$cmd" fail "restart failed"
            last_window_skipped=1
            return
        fi
    fi

    last_window_skipped=0
    window_count=$((window_count + 1))
    last_window="$name"

    if [[ -n "$workdir" ]]; then
        tmux send-keys -t "$session:$name" "cd $workdir" Enter
    fi
    tmux send-keys -t "$session:$name" "$cmd" Enter
}

send_continuation() {
    local cmd="$1"
    if [[ -z "$session" || -z "$last_window" ]]; then
        echo "Warning: '+' line with no prior window, ignoring: $cmd" >&2
        return
    fi
    if [[ $last_window_skipped -eq 1 ]]; then
        return
    fi
    tmux send-keys -t "$session:$last_window" "$cmd" Enter
}

# --- Main parse loop ---
while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip inline comments and trailing whitespace
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip blank lines
    [[ -z "$line" ]] && continue

    # Session header: [name]
    if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
        flush_session
        session="${BASH_REMATCH[1]}"
        printf "\n%s[%s]%s\n" "$BOLD" "$session" "$RESET"
        continue
    fi

    # No active session — skip
    [[ -z "$session" ]] && continue

    # Continuation command: + cmd
    if [[ "$line" =~ ^\+\ (.+)$ ]]; then
        send_continuation "${BASH_REMATCH[1]}"
        continue
    fi

    # Window definition: - window-name = command
    if [[ "$line" =~ ^-\ ([^=]+)=\ *(.+)$ ]]; then
        win_name="${BASH_REMATCH[1]}"
        win_cmd="${BASH_REMATCH[2]}"
        # Trim trailing whitespace from window name
        win_name="${win_name%"${win_name##*[![:space:]]}"}"
        create_window "$win_name" "$win_cmd"
        continue
    fi

    # Session option: key = value
    if [[ "$line" =~ ^([^=]+)=\ *(.+)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        key="${key%"${key##*[![:space:]]}"}"
        val="${val%"${val##*[![:space:]]}"}"
        case "$key" in
            workdir) workdir="$val" ;;
            *) echo "Unknown option: $key" >&2 ;;
        esac
        continue
    fi

    echo "Warning: unrecognized line: $line" >&2
done < "$CONFIG"

# Flush the last session
flush_session

echo ""
echo "Done."
