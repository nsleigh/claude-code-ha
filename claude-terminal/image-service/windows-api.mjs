/**
 * Window bar: the tmux windows of the add-on's one session, `claude`.
 *
 * Every browser shows the same session, so a switch made here switches every
 * device, the same as Ctrl-b n. A new window starts the same way as the
 * first (CLAUDE_LAUNCH_CMD, from the tmux server's environment): Claude
 * straight away, or the session picker when auto_launch_claude is off.
 *
 * Windows are named by their tmux id (@3), never their number: numbers move
 * when a window closes (renumber-windows), and closing the wrong one would
 * end someone's work. The last window is never closed from here, since that
 * would end the session.
 *
 * tmux always runs through execFile with an argument array. State-changing
 * requests need the X-Window-Request header, which a cross-site form can't
 * send.
 */

import fs from 'node:fs';
import path from 'node:path';
import { execFile } from 'node:child_process';

export const SESSION = 'claude';
// Below this much free memory, + and the picker ask before starting another
// Claude. About two Claudes' worth (each uses roughly 450-500 MB, measured with the HA plugin).
export const LOW_MEMORY_MB = 1024;
export const CLAUDE_MB_ESTIMATE = 500;
// A Claude is busy while its footer offers "esc to interrupt" (it is
// thinking, or waiting on a command it runs) or counts background shells
// ("1 shell · ↓ to manage": idle at the prompt, but a command it started
// still runs, and closing the window would end it). Only the footer is read:
// the lines below the input box's bottom border (a row of ─), so the same
// words in the conversation, a reply quoting them, don't count. (Other signals don't work: an idle Claude redraws now and
// then, uses as much CPU as one waiting on a command, and its terminal title
// starts with the same ✳ either way.)
const BUSY_FOOTER = /esc to interrupt|\b\d+ shells?\b.*to manage/;
const RULE = /^\s*─{8,}\s*$/;
// A shell window is busy when something else runs in the foreground
const SHELLS = new Set(['bash', 'sh', 'ash', 'zsh', 'fish', 'dash']);

export function claudeBusy(screen) {
    const lines = String(screen || '').split('\n').filter((line) => line.trim());
    let rule = -1;
    for (let i = lines.length - 1; i >= 0; i--) {
        if (RULE.test(lines[i])) { rule = i; break; }
    }
    // No input box found: the last line only
    const footer = rule >= 0 ? lines.slice(rule + 1) : lines.slice(-1);
    return footer.some((line) => BUSY_FOOTER.test(line));
}

// pane_title last: a program sets it, so it may hold anything but a newline
// (tmux drops control characters), including tabs
const FIELDS = ['window_id', 'window_index', 'window_name', 'window_active',
    'window_activity', 'pane_pid', 'pane_current_command', 'pane_title'];
const FORMAT = FIELDS.map((f) => `#{${f}}`).join('\t');
const WINDOW_ID = /^@\d{1,6}$/;

function runTmux(args) {
    return new Promise((resolve) => {
        execFile('tmux', args, { timeout: 5000, maxBuffer: 1024 * 1024 }, (err, stdout, stderr) => {
            resolve({ ok: !err, stdout: stdout || '', stderr: (stderr || '').trim() });
        });
    });
}

// A process name (comm) that is Claude Code: its binary is called claude,
// and it may set its title to its version (2.1.327)
export function isClaudeName(name) {
    return name === 'claude' || /^\d+\.\d+\.\d+/.test(name);
}

/**
 * The conversation's name, from the terminal title Claude Code sets: "✳ "
 * (or a spinner) and the topic it gave the conversation, usually the name
 * /resume lists. Null until it has one: the title is then "Claude Code".
 */
export function conversationName(title) {
    const name = String(title || '').replace(/^[^\p{L}\p{N}]+/u, '').trim().slice(0, 80);
    return name && name !== 'Claude Code' ? name : null;
}

/**
 * The label for a window. tmux names a window after its pane's process group
 * leader, and the launch command's `bash -c` keeps Claude in its own group,
 * so every window would say bash. So look at what runs in the window: Claude
 * (by its conversation's name when it has one), or the session picker (its
 * script name, cut to 15 letters by the kernel). A name set with Ctrl-b ,
 * (no longer the pane's command) is kept as it is.
 */
export function windowLabel(window, tree) {
    if (window.name && window.name !== window.command) return window.name;
    if (tree.claude) return conversationName(window.title) || 'claude';
    if (tree.picker) return 'picker';
    return window.command || window.name || '';
}

export function parseWindows(stdout) {
    return stdout.split('\n').filter(Boolean).map((line) => {
        const [id, index, name, active, activity, pid, command, ...title] = line.split('\t');
        return {
            id,
            index: Number(index),
            name: name || '',
            active: active === '1',
            activity: Number(activity),
            pid: Number(pid),
            command: command || '',
            title: title.join(' ')
        };
    }).filter((w) => WINDOW_ID.test(w.id));
}

/** MemAvailable from /proc/meminfo, in MB, or null if it can't be read */
export function availableMemoryMB(procDir = '/proc') {
    try {
        const match = /^MemAvailable:\s+(\d+) kB/m.exec(fs.readFileSync(path.join(procDir, 'meminfo'), 'utf8'));
        return match ? Math.round(Number(match[1]) / 1024) : null;
    } catch {
        return null;
    }
}

/**
 * Each pane's process tree, keyed by its root pid: the shell and everything
 * below it (Claude, its tools, a build it runs). Its resident memory in MB,
 * and whether Claude or the session picker runs in it.
 */
export function processTrees(rootPids, procDir = '/proc') {
    const children = new Map();
    const rss = new Map();
    const names = new Map();
    let entries = [];
    try { entries = fs.readdirSync(procDir); } catch { return {}; }
    for (const entry of entries) {
        if (!/^\d+$/.test(entry)) continue;
        try {
            // status, not statm: its sizes are in kB, whatever the kernel's
            // page size (a Pi 5 kernel uses 16 kB pages)
            const status = fs.readFileSync(path.join(procDir, entry, 'status'), 'utf8');
            const ppid = Number(/^PPid:\s+(\d+)/m.exec(status)?.[1]);
            const rssKB = Number(/^VmRSS:\s+(\d+) kB/m.exec(status)?.[1] || 0);
            const pid = Number(entry);
            rss.set(pid, rssKB * 1024);
            names.set(pid, /^Name:\s+(.*)$/m.exec(status)?.[1] || '');
            if (!children.has(ppid)) children.set(ppid, []);
            children.get(ppid).push(pid);
        } catch {
            // Gone while reading
        }
    }
    const result = {};
    for (const root of rootPids) {
        const tree = { memoryMB: 0, claude: false, picker: false };
        let total = 0;
        const seen = new Set();
        const stack = [root];
        while (stack.length) {
            const pid = stack.pop();
            if (seen.has(pid)) continue;
            seen.add(pid);
            total += rss.get(pid) || 0;
            const name = names.get(pid) || '';
            if (isClaudeName(name)) tree.claude = true;
            if (name.startsWith('claude-session')) tree.picker = true;
            stack.push(...(children.get(pid) || []));
        }
        tree.memoryMB = rss.size ? Math.round(total / (1024 * 1024)) : null;
        result[root] = tree;
    }
    return result;
}

export function register(app, {
    tmux = runTmux,
    procDir = '/proc',
    // Set by run.sh (working_directory, default /config) before this service
    // starts; the first window was started there
    workdir = process.env.CLAUDE_WORKDIR || '/config'
} = {}) {
    async function isBusy(w, tree) {
        if (!tree.claude) return !SHELLS.has(w.command) && !tree.picker;
        const res = await tmux(['capture-pane', '-p', '-t', w.id]);
        return res.ok && claudeBusy(res.stdout);
    }

    async function list() {
        const res = await tmux(['list-windows', '-t', `=${SESSION}`, '-F', FORMAT]);
        if (!res.ok) return null;
        const windows = parseWindows(res.stdout);
        const trees = processTrees(windows.map((w) => w.pid), procDir);
        const availableMB = availableMemoryMB(procDir);
        return {
            windows: await Promise.all(windows.map(async (w) => {
                const tree = trees[w.pid] || { memoryMB: null, claude: false, picker: false };
                return {
                    id: w.id,
                    index: w.index,
                    label: windowLabel(w, tree),
                    active: w.active,
                    claude: tree.claude,
                    busy: await isBusy(w, tree),
                    memoryMB: tree.memoryMB
                };
            })),
            memory: {
                availableMB,
                claudeMB: CLAUDE_MB_ESTIMATE,
                low: availableMB !== null && availableMB < LOW_MEMORY_MB
            }
        };
    }

    async function respond(res) {
        const state = await list();
        if (!state) return res.status(503).json({ error: 'The terminal session is not running' });
        res.json(state);
    }

    function guarded(handler) {
        return async (req, res) => {
            res.set('Cache-Control', 'no-store');
            if (req.get('X-Window-Request') !== '1') return res.sendStatus(403);
            await handler(req, res);
        };
    }

    async function known(req, res) {
        const id = req.params.id;
        if (!WINDOW_ID.test(id)) {
            res.status(400).json({ error: 'Not a window id' });
            return null;
        }
        const state = await list();
        if (!state) {
            res.status(503).json({ error: 'The terminal session is not running' });
            return null;
        }
        if (!state.windows.some((w) => w.id === id)) {
            res.status(404).json({ error: 'That window has already closed' });
            return null;
        }
        return state;
    }

    app.get('/api/windows', async (req, res) => {
        res.set('Cache-Control', 'no-store');
        await respond(res);
    });

    app.post('/api/windows', guarded(async (req, res) => {
        // Becomes the current window. -c: without it tmux starts the window
        // in this service's own folder (/), not the session's
        const result = await tmux(['new-window', '-t', `=${SESSION}:`, '-c', workdir,
            'bash', '-c', 'eval "$CLAUDE_LAUNCH_CMD"']);
        if (!result.ok) return res.status(500).json({ error: result.stderr || 'Could not open a window' });
        await respond(res);
    }));

    app.post('/api/windows/:id/select', guarded(async (req, res) => {
        if (!await known(req, res)) return;
        const result = await tmux(['select-window', '-t', req.params.id]);
        if (!result.ok) return res.status(500).json({ error: result.stderr || 'Could not switch' });
        await respond(res);
    }));

    app.post('/api/windows/:id/close', guarded(async (req, res) => {
        const state = await known(req, res);
        if (!state) return;
        if (state.windows.length < 2) {
            return res.status(409).json({ error: 'The last window stays open: closing it would end the session' });
        }
        const result = await tmux(['kill-window', '-t', req.params.id]);
        if (!result.ok) return res.status(500).json({ error: result.stderr || 'Could not close the window' });
        await respond(res);
    }));
}
