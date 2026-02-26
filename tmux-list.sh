#!/usr/bin/env bash
set -euo pipefail

# --- Color setup ---
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
    BOLD=$(tput bold)
    CYAN=$(tput setaf 6)
    RESET=$(tput sgr0)
else
    BOLD="" CYAN="" RESET=""
fi

# Check if tmux server is running
if ! tmux list-sessions &>/dev/null; then
    echo "No tmux sessions running."
    exit 0
fi

# --- Print header ---
printf "%-17s %s  %-20s %s\n" "SESSION" "#" "WINDOW" "COMMAND"
printf "%-17s %s  %-20s %s\n" "───────────────" "──" "───────────────────" "───────────────────"

# --- Print windows grouped by session ---
prev_session=""

while IFS='|' read -r sess_name win_idx win_name pane_cmd win_active; do
    # Blank line between sessions
    if [[ -n "$prev_session" && "$sess_name" != "$prev_session" ]]; then
        echo ""
    fi

    # Session name: only on first window of each session
    local_sess=""
    if [[ "$sess_name" != "$prev_session" ]]; then
        local_sess="$sess_name"
    fi

    # Mark active window
    local_name="$win_name"
    if [[ "$win_active" == "1" ]]; then
        local_name="${CYAN}${win_name} *${RESET}"
        # Pad to account for escape codes in printf width
        printf "%-17s %2s  %-$((20 + ${#CYAN} + ${#RESET}))s %s\n" \
            "$local_sess" "$win_idx" "$local_name" "$pane_cmd"
    else
        printf "%-17s %2s  %-20s %s\n" \
            "$local_sess" "$win_idx" "$local_name" "$pane_cmd"
    fi

    prev_session="$sess_name"
done < <(tmux list-windows -a -F '#{session_name}|#{window_index}|#{window_name}|#{pane_current_command}|#{window_active}')
