#!/bin/bash

# Claude Session Picker - Interactive menu for choosing Claude session type
# Provides options for new session, continue, resume, manual command, or regular shell

# Get Claude flags from environment. CLAUDE_FLAGS (set by run.sh) is shell
# text, so launches eval it once and quoting in claude_extra_args survives.
get_claude_flags() {
    local flags="${CLAUDE_FLAGS-}"
    # Older run.sh only exported the dangerous-mode switch
    if [ -z "${CLAUDE_FLAGS+set}" ] && [ "${CLAUDE_DANGEROUS_MODE}" = "true" ]; then
        flags="--dangerously-skip-permissions"
    fi
    if [[ "$flags" == *"--dangerously-skip-permissions"* ]]; then
        echo "⚠️  Running in DANGEROUS mode (unrestricted file access)" >&2
        # Set IS_SANDBOX=1 to allow dangerous mode when running as root
        export IS_SANDBOX=1
    fi
    echo "$flags"
}

# Claude Code puts the terminal in raw mode and turns on extended keyboard
# reporting. If it dies without undoing that (crash, OOM, kill), the menu
# can't see Enter and nothing echoes, so it looks frozen (#32, #36).
reset_terminal() {
    [ -t 0 ] || return 0
    stty sane 2>/dev/null
    # Keyboard protocols (kitty, modifyOtherKeys), bracketed paste, focus
    # events, mouse tracking, alternate screen; then show the cursor again
    printf '\033[<u\033[>4;0m\033[?2004l\033[?1004l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1049l\033[?25h'
}

# The box and the full menu labels need 64 columns. A phone shows about 45,
# where they wrap into a broken frame, so narrow terminals get a short form.
PICKER_WIDE_COLS=64

# Width of the terminal on stdin. stty, not tput: the image has no ncurses
# tools. Not a terminal (or no answer): assume 80.
term_cols() {
    local size cols
    size=$(stty size 2>/dev/null) || size=''
    cols=${size#* }
    case "$cols" in
        ''|*[!0-9]*|0) cols=80 ;;
    esac
    echo "$cols"
}

is_narrow() {
    [ "$(term_cols)" -lt "$PICKER_WIDE_COLS" ]
}

show_banner() {
    reset_terminal
    clear
    if is_narrow; then
        local rule
        rule=$(printf '%*s' "$(term_cols)" '' | sed 's/ /═/g')
        echo "🤖 Claude Terminal · Session Picker"
        echo "$rule"
        echo ""
        return
    fi
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    🤖 Claude Terminal                        ║"
    echo "║                   Interactive Session Picker                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

# Only offer the manual update option when run.sh has set up a persistent
# Claude install (use_persistent_claude: true) for it to update.
is_persistent_claude_enabled() {
    [ "${USE_PERSISTENT_CLAUDE:-false}" = "true" ]
}

# Other windows of the tmux session:
# one line each, "@id<TAB>number<TAB>label<TAB>kind", kind being claude,
# picker or empty, whatever the label. Nothing outside tmux.
# PICKER_TMUX lets the tests stand in for tmux.
PICKER_TMUX=${PICKER_TMUX:-tmux}

# Every process: "pid ppid name" (name is the kernel's 15-letter comm).
# cat, not awk on the files: a process that exits between the glob and the
# read would make BusyBox awk stop at its missing file, losing every process
# after it, and with them the labels; cat skips it and goes on. The pid comes
# from the file's own Pid: line. PICKER_PROC lets the tests stand in for /proc.
process_table() {
    cat "${PICKER_PROC:-/proc}"/[0-9]*/status 2>/dev/null |
        awk '/^Name:/ { name = $2 } /^Pid:/ { pid = $2 } /^PPid:/ { print pid, $2, name }'
}

# What each window runs, for its label. tmux names a
# window after its pane's process group leader, which for the launch
# command's `bash -c` is bash, so look for Claude (named claude, or its
# version) or this picker among the window's processes. A Claude is named by
# its conversation: the terminal title it sets, "✳ <topic>", until then
# "Claude Code". A name set with Ctrl-b , (no longer the pane's command) is
# kept.
other_windows() {
    [ -n "${TMUX:-}" ] || return 0
    local own
    own=$("$PICKER_TMUX" display-message -p -t "${TMUX_PANE:-}" '#{window_id}' 2>/dev/null) || own=''
    "$PICKER_TMUX" list-windows -F $'#{window_id}\t#{window_index}\t#{window_name}\t#{pane_current_command}\t#{pane_pid}\t#{pane_title}' 2>/dev/null |
        awk -F'\t' -v own="$own" '
            NR == FNR { split($0, p, " "); parent[p[1]] = p[2]; name[p[1]] = p[3]; next }
            function kind(root,   pid, q, d, n, found) {
                found = ""
                for (pid in parent) {
                    q = pid
                    for (d = 0; d < 64 && q != "" && q != "0"; d++) {
                        if (q == root) {
                            n = name[pid]
                            if (n == "claude" || n ~ /^[0-9]+\.[0-9]+\.[0-9]+/) return "claude"
                            if (n ~ /^claude-session/) found = "picker"
                            break
                        }
                        q = parent[q]
                    }
                }
                return found
            }
            $1 == own { next }
            {
                k = kind($5)
                label = ($3 == $4 && k != "") ? k : $3
                if ($3 == $4 && k == "claude") {
                    # The title is the rest of the line, tabs and all
                    title = $0
                    for (i = 1; i <= 5; i++) sub(/^[^\t]*\t/, "", title)
                    gsub(/\t/, " ", title)
                    sub(/^[^A-Za-z0-9]+/, "", title)
                    if (title != "" && title != "Claude Code") label = substr(title, 1, 80)
                }
                printf "%s\t%s\t%s\t%s\n", $1, $2, label, k
            }' <(process_table) -
}

# "1 claude, 3 Fix the lights…": names cut at 16 characters, so the line
# stays short (the w) list shows them in full)
describe_windows() {
    awk -F'\t' '{
        name = $3
        if (length(name) > 16) name = substr(name, 1, 15) "…"
        printf "%s%s %s", (NR > 1 ? ", " : ""), $2, name
    } END { if (NR) print "" }'
}

# Below this much free memory, ask before starting another Claude (each uses
# roughly 500-600 MB, and the add-on has no memory limit of its own).
LOW_MEMORY_MB=1024
CLAUDE_MEMORY_MB=550

available_memory_mb() {
    awk '/^MemAvailable:/ { printf "%d\n", $2 / 1024 }' "${PICKER_MEMINFO:-/proc/meminfo}" 2>/dev/null
}

# True to go ahead: enough memory, or the user said yes
memory_ok() {
    local free answer
    free=$(available_memory_mb)
    case "$free" in ''|*[!0-9]*) return 0 ;; esac
    [ "$free" -lt "$LOW_MEMORY_MB" ] || return 0
    echo ""
    echo "⚠️  Only ${free} MB of memory is free, and each Claude uses about ${CLAUDE_MEMORY_MB} MB."
    printf "Start Claude anyway? [y/N] " >&2
    read -r answer
    [[ "$answer" =~ ^[Yy] ]]
}

# Menu item numbers shift depending on whether the update option is shown,
# so both the menu display and the choice handling read from these.
compute_menu_numbers() {
    if is_persistent_claude_enabled; then
        NUM_UPDATE=7
        NUM_BASH=8
        NUM_EXIT=9
    else
        NUM_UPDATE=""
        NUM_BASH=7
        NUM_EXIT=8
    fi
}

LATEST_VERSION_CACHE="${XDG_CACHE_HOME:-/data/.cache}/claude-latest-version"
LATEST_VERSION_TTL=3600

# "2.1.226 (Claude Code)" -> "2.1.226"
get_installed_version() {
    [ -x /usr/local/bin/claude ] || return 0
    /usr/local/bin/claude --version 2>/dev/null | awk 'NR==1 {print $1}'
}

# The version the Update option would install. A pinned spec is its
# own answer; otherwise ask the npm registry, cached so the menu redraw loop
# does not hit the network every time. Prints nothing when it cannot tell.
get_latest_version() {
    local spec="${CLAUDE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
    local pinned="${spec##*@}"
    case "$pinned" in
        [0-9]*) echo "$pinned"; return 0 ;;
    esac

    local now cached_at cached_version
    now=$(date +%s)
    if [ -f "$LATEST_VERSION_CACHE" ]; then
        read -r cached_at cached_version < "$LATEST_VERSION_CACHE"
        if [ -n "$cached_version" ] && [ $((now - ${cached_at:-0})) -lt "$LATEST_VERSION_TTL" ]; then
            echo "$cached_version"
            return 0
        fi
    fi

    local latest
    latest=$(curl -fsS --max-time 3 https://registry.npmjs.org/@anthropic-ai/claude-code/latest 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    if [ -n "$latest" ]; then
        mkdir -p "$(dirname "$LATEST_VERSION_CACHE")" 2>/dev/null
        echo "$now $latest" > "$LATEST_VERSION_CACHE" 2>/dev/null
        echo "$latest"
    fi
}

# True when $1 is strictly newer than $2.
version_is_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

update_menu_label() {
    local installed latest
    installed=$(get_installed_version)
    latest=$(get_latest_version)

    if [ -z "$latest" ]; then
        echo "Update Claude Code (latest version unknown)"
    elif [ -n "$installed" ] && version_is_newer "$latest" "$installed"; then
        echo "Update Claude Code ($installed → $latest available)"
    else
        echo "Update Claude Code (${installed:-$latest}, up to date)"
    fi
}

show_menu() {
    local ver="unknown" others
    others=$(other_windows)
    if [ -x /usr/local/bin/claude ]; then
        ver=$(/usr/local/bin/claude --version 2>/dev/null || echo "unknown")
    fi

    # 🔧, not ⚙️: ⚙️ (with the emoji selector) is one cell wide in some
    # terminals and two in others, so no spacing after it looks right everywhere
    if is_narrow; then
        echo "Claude Code: ${ver% (Claude Code)}"
        echo ""
        echo "Choose a session:"
        echo ""
        echo "  1) 🆕 New session (default)"
        echo "  2) ⏩ Continue last conversation (-c)"
        echo "  3) 📋 Resume a conversation (-r)"
        echo "  4) 🔧 Custom command (manual flags)"
        echo "  5) 🔐 Claude login helper"
        echo "  6) 🐙 GitHub CLI login"
        if is_persistent_claude_enabled; then
            local label detail
            label=$(update_menu_label)
            detail=${label#Update Claude Code (}
            detail=${detail%)}
            echo "  ${NUM_UPDATE}) 🔄 Update Claude Code"
            echo "        ${detail}"
        fi
        echo "  ${NUM_BASH}) 🐚 Bash shell"
        echo "  ${NUM_EXIT}) ❌ Exit"
        # 🔀, not 🪟: 🪟 (Unicode 13) is drawn two cells wide but counted as
        # one by the terminal, so it ran into the text
        if [ -n "$others" ]; then
            echo "  w) 🔀 Switch window"
            echo ""
            echo "Other windows: $(printf '%s\n' "$others" | wc -l | tr -d ' ')"
        fi
        echo ""
        return
    fi

    echo "Claude Code version: $ver"
    echo ""
    echo "Choose your Claude session type:"
    echo ""
    echo "  1) 🆕 New interactive session (default)"
    echo "  2) ⏩ Continue most recent conversation (-c)"
    echo "  3) 📋 Resume from conversation list (-r)"
    echo "  4) 🔧 Custom Claude command (manual flags)"
    echo "  5) 🔐 Claude authentication helper"
    echo "  6) 🐙 GitHub CLI login (gh auth)"
    if is_persistent_claude_enabled; then
        echo "  ${NUM_UPDATE}) 🔄 $(update_menu_label)"
    fi
    echo "  ${NUM_BASH}) 🐚 Drop to bash shell"
    echo "  ${NUM_EXIT}) ❌ Exit"
    if [ -n "$others" ]; then
        echo "  w) 🔀 Switch to another window"
        echo ""
        echo "Other windows: $(printf '%s\n' "$others" | describe_windows)"
    fi
    echo ""
}

show_prompt() {
    printf "Enter your choice [1-%s] (default: 1): " "$NUM_EXIT"
}

get_user_choice() {
    local choice cols now status
    # Send prompt to stderr to avoid capturing it with the return value
    show_prompt >&2
    # The menu is often drawn before anyone is watching: at start-up the
    # session has tmux's default 80 columns until a browser attaches. Redraw
    # when the width changes. Typed text waits in the terminal's line buffer
    # until Enter, so a redraw doesn't lose it.
    cols=$(term_cols)
    while :; do
        if read -r -t 1 choice; then
            break
        else
            status=$?
        fi
        # Not a timeout (end of input): fall through to the default
        [ "$status" -gt 128 ] || break
        now=$(term_cols)
        if [ "$now" != "$cols" ]; then
            cols=$now
            { show_banner; show_menu; show_prompt; } >&2
        fi
    done
    
    # Default to 1 if empty
    if [ -z "$choice" ]; then
        choice=1
    fi
    
    # Trim whitespace and return only the choice
    choice=$(echo "$choice" | tr -d '[:space:]')
    echo "$choice"
}

launch_claude_new() {
    local flags
    flags=$(get_claude_flags)
    echo "🚀 Starting new Claude session..."
    sleep 1
    eval "/usr/local/bin/claude $flags"
    # Returns here when Claude exits, loop in main() shows menu again
}

launch_claude_continue() {
    local flags
    flags=$(get_claude_flags)
    echo "⏩ Continuing most recent conversation..."
    sleep 1
    eval "/usr/local/bin/claude -c $flags"
}

launch_claude_resume() {
    local flags
    flags=$(get_claude_flags)
    echo "📋 Opening conversation list for selection..."
    sleep 1
    eval "/usr/local/bin/claude -r $flags"
}

launch_claude_custom() {
    local base_flags
    base_flags=$(get_claude_flags)
    echo ""
    echo "Enter your Claude command (e.g., 'claude --help' or 'claude -p \"hello\"'):"
    echo "Available flags: -c (continue), -r (resume), -p (print), --model,"
    echo "                 --dangerously-skip-permissions, etc."
    if [ -n "$base_flags" ]; then
        echo "Note: these will be added automatically: $base_flags"
    fi
    echo -n "> claude "
    read -r custom_args

    if [ -z "$custom_args" ]; then
        echo "No arguments provided. Starting default session..."
        launch_claude_new
    else
        echo "🚀 Running: claude $custom_args $base_flags"
        sleep 1
        eval "/usr/local/bin/claude $custom_args $base_flags"
    fi
}

switch_window() {
    local windows choice id index label
    windows=$(other_windows)
    if [ -z "$windows" ]; then
        echo "No other windows."
        sleep 1
        return
    fi
    echo ""
    echo "Switch to:"
    while IFS=$'\t' read -r id index label _; do
        echo "  ${index}) ${label}"
    done <<<"$windows"
    printf "Window number (Enter to go back): " >&2
    read -r choice
    [ -n "$choice" ] || return 0
    id=$(awk -F'\t' -v n="$choice" '$2 == n { print $1 }' <<<"$windows")
    if [ -n "$id" ]; then
        "$PICKER_TMUX" select-window -t "$id"
    else
        echo "❌ No window ${choice}"
        sleep 1
    fi
}

launch_update_claude() {
    local persistent_root="${PERSISTENT_CLAUDE_ROOT:-/data/npm}"
    local claude_link="${CLAUDE_BIN_LINK:-/usr/local/bin/claude}"
    local claude_npm_spec="${CLAUDE_NPM_SPEC:-@anthropic-ai/claude-code@latest}"
    local persistent_bin="$persistent_root/bin/claude"
    local running answer status

    # npm replaces the files a Claude in another window was started from. It
    # keeps running the old version until restarted, but could fail if it
    # loads a file that changed.
    running=$(other_windows | awk -F'\t' '$4 == "claude" { printf "%s%s", (n++ ? ", " : ""), $2 }')
    if [ -n "$running" ]; then
        echo ""
        echo "⚠️  Claude is running in window ${running}. It keeps the old version until"
        echo "   restarted, and could fail if it loads a file the update changes."
        printf "Update anyway? [y/N] " >&2
        read -r answer
        [[ "$answer" =~ ^[Yy] ]] || return 0
    fi

    echo "🔄 Updating Claude Code (${claude_npm_spec})..."
    mkdir -p "$persistent_root"
    # One update at a time: two npm installs into one folder can leave it
    # half installed
    status=0
    (
        if command -v flock >/dev/null 2>&1; then
            flock -n 9 || exit 75
        fi
        NPM_CONFIG_PREFIX="$persistent_root" npm install -g "$claude_npm_spec" --prefer-online
    ) 9>"$persistent_root/.update-lock" || status=$?
    if [ "$status" -eq 75 ]; then
        echo "⏳ Another window is already updating Claude Code. Try again when it has finished."
    elif [ "$status" -eq 0 ]; then
        rm -f "$LATEST_VERSION_CACHE"
        if [ -x "$persistent_bin" ]; then
            ln -sf "$persistent_bin" "$claude_link"
            local new_version
            new_version=$("$claude_link" --version 2>/dev/null || echo "unknown")
            echo "✅ Claude Code updated: $new_version"
        else
            echo "⚠️  Update ran but no binary was found at $persistent_bin"
        fi
    else
        echo "❌ Update failed. Keeping the existing installed version."
    fi

    printf "Press Enter to return to menu..." >&2
    read -r
}

launch_auth_helper() {
    echo "🔐 Starting Claude authentication helper..."
    sleep 1
    /opt/scripts/claude-auth-helper.sh
}

launch_github_auth() {
    echo ""
    echo "🐙 GitHub CLI Authentication"
    echo "════════════════════════════"
    echo ""

    # Check if gh is installed
    if ! command -v gh &>/dev/null; then
        echo "❌ GitHub CLI (gh) is not installed!"
        echo "   Update to Claude Terminal Pro v2.0.4+ to get gh pre-installed."
        echo ""
        printf "Press Enter to return to menu..." >&2
        read -r
        return
    fi

    # Check current auth status
    echo "Checking current authentication status..."
    echo ""
    if gh auth status 2>/dev/null; then
        echo ""
        echo "✅ You are already authenticated!"
        echo ""
        echo "Options:"
        echo "  1) Keep current login"
        echo "  2) Login to a different account"
        echo ""
        printf "Choice [1-2] (default: 1): " >&2
        read -r auth_choice

        if [ "$auth_choice" != "2" ]; then
            echo ""
            printf "Press Enter to return to menu..." >&2
            read -r
            return
        fi
    fi

    echo ""
    echo "Choose authentication method:"
    echo ""
    echo "  1) 🌐 Browser login (if you have browser access)"
    echo "  2) 🔑 Token login (recommended for containers)"
    echo ""
    printf "Choice [1-2] (default: 2): " >&2
    read -r method_choice

    echo ""
    if [ "$method_choice" = "1" ]; then
        echo "Starting browser authentication..."
        gh auth login --web
    else
        echo "To create a personal access token:"
        echo ""
        echo "  1. Go to: https://github.com/settings/tokens"
        echo "  2. Click 'Generate new token (classic)'"
        echo "  3. Select scopes: repo, read:org, workflow"
        echo "  4. Generate and copy the token"
        echo ""
        gh auth login --with-token <<< "$(read -rsp 'Paste your token: ' token; echo "$token")" 2>/dev/null || {
            # Fallback to interactive if the above fails
            echo ""
            gh auth login -p https -h github.com
        }
    fi

    echo ""
    echo "Verifying authentication..."
    if gh auth status 2>/dev/null; then
        echo ""
        echo "✅ GitHub authentication successful!"
        echo "   Credentials saved to: $GH_CONFIG_DIR"
        echo "   They will persist across reboots."
    else
        echo ""
        echo "⚠️  Authentication may have failed. Try again or use 'gh auth login' from bash."
    fi

    echo ""
    printf "Press Enter to return to menu..." >&2
    read -r
}

launch_bash_shell() {
    echo "🐚 Dropping to bash shell..."
    echo "Tip: Run 'claude' manually, type 'exit' to return to this menu"
    sleep 1
    bash
    # Returns here when user types 'exit', loop in main() shows menu again
}

exit_session_picker() {
    echo "👋 Goodbye!"
    exit 0
}

# Main execution flow
main() {
    while true; do
        compute_menu_numbers
        show_banner
        show_menu
        choice=$(get_user_choice)

        case "$choice" in
            1)
                memory_ok && launch_claude_new
                ;;
            2)
                memory_ok && launch_claude_continue
                ;;
            3)
                memory_ok && launch_claude_resume
                ;;
            4)
                memory_ok && launch_claude_custom
                ;;
            5)
                launch_auth_helper
                ;;
            6)
                launch_github_auth
                ;;
            w|W)
                switch_window
                ;;
            "$NUM_UPDATE")
                if is_persistent_claude_enabled; then
                    launch_update_claude
                fi
                ;;
            "$NUM_BASH")
                launch_bash_shell
                ;;
            "$NUM_EXIT")
                exit_session_picker
                ;;
            *)
                echo ""
                echo "❌ Invalid choice: '$choice'"
                echo "Please select a number between 1-${NUM_EXIT}"
                echo ""
                printf "Press Enter to continue..." >&2
                read -r
                ;;
        esac
    done
}

# Run main function, unless sourced by the tests
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi