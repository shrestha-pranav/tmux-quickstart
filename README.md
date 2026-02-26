# tmux-quickstart

Declarative tmux session manager. Define sessions and windows in a config file, run one script to bring them all up.

## Quickstart

```bash
# Create sessions/windows from default config (./sessions.conf)
./tmux-start.sh

# Re-run safely — existing windows are skipped
./tmux-start.sh

# Kill and recreate all windows
./tmux-start.sh --restart

# Use a different config file
./tmux-start.sh ~/my-sessions.conf

# Combine flags
./tmux-start.sh -r ~/my-sessions.conf
```

### Config format

```ini
# Comment
[session-name]
workdir = ~/projects/myapp
- window-name = command to run
+ followup command sent to same window

[another-session]
- editor = vim
- shell = bash
```

**Line types:**
| Prefix | Meaning |
|--------|---------|
| `[name]` | Start a new session |
| `key = value` | Session option (`workdir` supported) |
| `- name = cmd` | Create a window and send a command |
| `+ cmd` | Send an additional command to the last window |
| `#` | Comment (inline comments also supported) |

### Window management behavior

| Session exists? | Window exists? | `--restart`? | Action |
|:-:|:-:|:-:|---|
| No | — | — | Create session with window |
| Yes | No | — | Add window to session |
| Yes | Yes | No | Skip (logged as ⊘) |
| Yes | Yes | Yes | Kill window, recreate |

## Architecture

`tmux-start.sh` is a single-pass state machine:

1. **Argument parsing** — `while/case` loop handles `-r`/`--restart`, `-h`/`--help`, and a positional config path
2. **Color detection** — checks `[[ -t 1 ]]` and `tput colors` to decide between Unicode markers (✓/✗/⊘) and text fallbacks ([PASS]/[FAIL]/[SKIP])
3. **Line-by-line config parsing** — reads the config file, strips comments and whitespace, then matches each line against four patterns: session header, session option, window definition, continuation command
4. **Check-then-act window management** — for each window, checks both session and window existence via `tmux has-session` and `tmux list-windows`, then selects from four actions (create session, add window, skip, or restart)
5. **Colored output** — `log_result` prints one line per window with a status marker, window name, and truncated command

State variables (`session`, `workdir`, `window_count`, `last_window`, `last_window_skipped`) are reset by `flush_session` at each new `[session]` header.

### Extending

- **New session options**: add cases to the `case "$key"` block (alongside `workdir`)
- **New flags**: add entries to the argument-parsing `case "$1"` block
- **New line types**: add regex patterns to the main parse loop before the fallback warning

## Utility scripts

### `tmux-list.sh`

Lists all active tmux sessions and windows in a formatted table:

```bash
./tmux-list.sh
```

```
SESSION           #  WINDOW               COMMAND
───────────────  ── ───────────────────  ───────────────────
docker            0  native-ubuntu2404 *  bash
                  1  builder              make

server            0  jupyter *            jupyter
```

- Active window marked with `*` (cyan when color is available)
- Sessions grouped with blank-line separators
- Prints "No tmux sessions running." when the tmux server isn't up
