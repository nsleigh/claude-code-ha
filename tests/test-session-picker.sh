#!/usr/bin/env bash
# Session picker layout: the box banner and full labels on a wide terminal,
# a short form that fits a phone (about 45 columns) on a narrow one.
set -euo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
    echo "FAIL (session picker): $*" >&2
    exit 1
}

# shellcheck source=/dev/null
source "$repo_root/claude-terminal/scripts/claude-session-picker.sh"

# No terminal to reset or clear, and no network for the update label
reset_terminal() { :; }
clear() { :; }
get_installed_version() { echo 2.1.319; }
get_latest_version() { echo 2.1.319; }

# Display width: emoji count two cells, the emoji selector none
width() {
    python3 -c '
import sys
for line in sys.stdin.read().splitlines():
    w = 0
    for ch in line:
        o = ord(ch)
        if o == 0xFE0F: continue
        w += 2 if (o >= 0x1F000 or o in (0x23E9, 0x274C)) else 1
    print(w)'
}

render() {  # render <cols>
    COLS="$1"
    stty() { [ "$1" = size ] && echo "24 $COLS"; }
    compute_menu_numbers
    { show_banner; show_menu; } 2>/dev/null
}

for persistent in false true; do
    export USE_PERSISTENT_CLAUDE=$persistent
    compute_menu_numbers

    narrow=$(render 45)
    max=$(printf '%s\n' "$narrow" | width | sort -n | tail -1)
    [ "$max" -le 45 ] || fail "a line is $max cells wide at 45 columns (persistent=$persistent)"
    ! grep -q '╔' <<<"$narrow" || fail "no box banner on a narrow terminal"
    grep -q 'Session Picker' <<<"$narrow" || fail "narrow header missing"
    grep -q '^  1) .*New session' <<<"$narrow" || fail "narrow menu missing option 1"
    grep -q "^  ${NUM_EXIT}) .*Exit" <<<"$narrow" || fail "narrow menu missing Exit"
    if [ "$persistent" = true ]; then
        grep -q '^  7) .*Update Claude Code$' <<<"$narrow" || fail "narrow update option"
        grep -q '^        2.1.319, up to date$' <<<"$narrow" || fail "narrow update detail line"
    fi

    wide=$(render 80)
    grep -q '╔' <<<"$wide" || fail "box banner on a wide terminal"
    grep -q 'Continue most recent conversation (-c)' <<<"$wide" || fail "full labels on a wide terminal"
    max=$(printf '%s\n' "$wide" | width | sort -n | tail -1)
    [ "$max" -le 64 ] || fail "wide layout is $max cells, more than 64"
done

# Option 4 uses 🔧: ⚙️ is one cell in some terminals and two in others
! grep -v '^ *#' "$repo_root/claude-terminal/scripts/claude-session-picker.sh" | grep -q '⚙' || \
    fail "the menu should not use ⚙️, whose width varies between terminals"
grep -c '4) 🔧 ' "$repo_root/claude-terminal/scripts/claude-session-picker.sh" | grep -qx 2 || \
    fail "option 4 should show 🔧 and one space in both menus"

# Other windows: listed above the prompt, with w) to switch. A stand-in tmux
# answers for window @1 (this one) of three.
fake_tmux="$tmp_dir/tmux"
cat > "$fake_tmux" <<'TMUX'
#!/bin/bash
case "$1" in
    display-message) echo '@1' ;;
    list-windows) printf '@1\t1\tbash\tbash\t100\t✳ Claude Code\n@4\t2\tbash\tbash\t200\t✳ Claude Code\n@7\t3\tbash\tbash\t300\thomeassistant\n@9\t4\tbuild\tbash\t400\t✳ Build\n@11\t5\tbash\tbash\t500\t⠐ Fix the\tkitchen lights\n' ;;
    select-window) echo "$*" >> "$TMUX_LOG" ;;
esac
TMUX
chmod +x "$fake_tmux"
export PICKER_TMUX="$fake_tmux" TMUX_LOG="$tmp_dir/tmux.log" TMUX=/tmp/fake,1,0 TMUX_PANE=%1
export USE_PERSISTENT_CLAUDE=true

# Each window's processes: 1 is this picker, 2 runs Claude (as its version)
# under the picker, 3 is a plain shell, 4 was renamed but runs Claude
fake_proc="$tmp_dir/proc"
for entry in "100 1 bash" "101 100 claude-session-" "200 1 bash" "201 200 claude-session-" \
             "202 201 2.1.327" "300 1 bash" "400 1 bash" "401 400 claude" "500 1 bash" "501 500 claude"; do
    read -r pid ppid name <<<"$entry"
    mkdir -p "$fake_proc/$pid"
    printf 'Name:\t%s\nState:\tS\nPid:\t%s\nPPid:\t%s\n' "$name" "$pid" "$ppid" > "$fake_proc/$pid/status"
done
export PICKER_PROC="$fake_proc"
# A process that exits between the glob and the read: its status can't be
# read (a directory stands in), and the processes after it must still count
mkdir -p "$fake_proc/150/status"

[ "$(other_windows | cut -f1,3,4 | tr '\t\n' ': ')" = "@4:claude:claude @7:bash: @9:build:claude @11:Fix the kitchen lights:claude " ] || \
    fail "other_windows: Claude found by process, a shell stays bash, a renamed window keeps its name, this window left out (got: $(other_windows | tr '\t\n' ': '))"

wide=$(render 80)
grep -q '^  w) 🔀 Switch to another window$' <<<"$wide" || fail "wide menu: switch option"
grep -q '^Other windows: 2 claude, 3 bash, 4 build, 5 Fix the kitchen…$' <<<"$wide" || fail "wide menu: other windows line, a conversation name cut at 16"
max=$(printf '%s\n' "$wide" | width | sort -n | tail -1)
[ "$max" -le 64 ] || fail "wide layout with windows is $max cells"
narrow=$(render 45)
grep -q '^  w) 🔀 Switch window$' <<<"$narrow" || fail "narrow menu: switch option"
grep -q '^Other windows: 4$' <<<"$narrow" || fail "narrow menu: other windows count"
max=$(printf '%s\n' "$narrow" | width | sort -n | tail -1)
[ "$max" -le 45 ] || fail "narrow layout with windows is $max cells"

switch_window <<<"3" >/dev/null 2>&1
grep -qx 'select-window -t @7' "$TMUX_LOG" || fail "switching to window 3 selects its id (@7)"

# Memory: ask before starting Claude below about 1 GB free
meminfo="$tmp_dir/meminfo"
export PICKER_MEMINFO="$meminfo"
printf 'MemTotal: 4000000 kB\nMemAvailable: 3000000 kB\n' > "$meminfo"
memory_ok </dev/null >/dev/null 2>&1 || fail "with plenty free, Claude starts without asking"
printf 'MemTotal: 4000000 kB\nMemAvailable: 600000 kB\n' > "$meminfo"
! memory_ok <<<"n" >/dev/null 2>&1 || fail "low memory and no: Claude must not start"
memory_ok <<<"y" >/dev/null 2>&1 || fail "low memory and yes: Claude starts"
grep -q 'Only 585 MB of memory is free' <(memory_ok <<<"n" 2>/dev/null) || fail "the warning gives the free memory"
rm -f "$meminfo"
memory_ok </dev/null >/dev/null 2>&1 || fail "unreadable meminfo: start without asking"

# Update: warns about the Claude in window 2, and one update at a time
export PERSISTENT_CLAUDE_ROOT="$tmp_dir/npm" CLAUDE_BIN_LINK="$tmp_dir/claude-link"
npm() { echo ran >> "$tmp_dir/npm.log"; }
launch_update_claude <<<"n" > "$tmp_dir/update.out" 2>&1
grep -q 'Claude is running in window 2, 4, 5' "$tmp_dir/update.out" || fail "update must warn about running Claudes"
[ ! -e "$tmp_dir/npm.log" ] || fail "update answered no must not run npm"
launch_update_claude <<<$'y\n' >/dev/null 2>&1
[ "$(cat "$tmp_dir/npm.log")" = ran ] || fail "update answered yes runs npm"
if command -v flock >/dev/null 2>&1; then
    rm -f "$tmp_dir/npm.log"
    exec 8>"$PERSISTENT_CLAUDE_ROOT/.update-lock"
    flock -n 8
    launch_update_claude <<<$'y\n' > "$tmp_dir/update.out" 2>&1
    exec 8>&-
    grep -q 'Another window is already updating' "$tmp_dir/update.out" || fail "a second update must wait for the first"
    [ ! -e "$tmp_dir/npm.log" ] || fail "a second update must not run npm"
fi
unset -f npm
unset PICKER_TMUX TMUX TMUX_PANE PICKER_MEMINFO PICKER_PROC PERSISTENT_CLAUDE_ROOT CLAUDE_BIN_LINK

echo "Session picker layout tests passed"
