#!/usr/bin/env node
// Window bar API: labels, busy, memory, and the routes against a stand-in
// tmux (no express needed: register() only calls app.get / app.post)
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
    register, windowLabel, conversationName, parseWindows, availableMemoryMB, processTrees, claudeBusy, LOW_MEMORY_MB
} from '../claude-terminal/image-service/windows-api.mjs';

let passed = 0;
async function test(name, fn) {
    await fn();
    passed++;
    console.log('ok   ' + name);
}

// A fake /proc: meminfo plus a process tree per window
function fakeProc(availableKB, processes) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'proc-'));
    fs.writeFileSync(path.join(dir, 'meminfo'), `MemTotal: 8000000 kB\nMemAvailable: ${availableKB} kB\n`);
    for (const [pid, ppid, rssKB, name = 'bash'] of processes) {
        fs.mkdirSync(path.join(dir, String(pid)));
        fs.writeFileSync(path.join(dir, String(pid), 'status'),
            `Name:\t${name}\nPPid:\t${ppid}\nVmRSS:\t   ${rssKB} kB\n`);
    }
    fs.mkdirSync(path.join(dir, 'self'));
    return dir;
}

// Routes on a minimal app, called with a minimal req/res
function fakeApp() {
    const routes = {};
    const app = {
        get: (p, h) => { routes['GET ' + p] = h; },
        post: (p, h) => { routes['POST ' + p] = h; }
    };
    async function call(method, url, headers = {}) {
        for (const [key, handler] of Object.entries(routes)) {
            const [m, pattern] = key.split(' ');
            if (m !== method) continue;
            const re = new RegExp('^' + pattern.replace(/:id/, '([^/]+)') + '$');
            const match = re.exec(url);
            if (!match) continue;
            const res = {
                statusCode: 200, body: undefined,
                set() { return res; },
                status(code) { res.statusCode = code; return res; },
                json(body) { res.body = body; return res; },
                sendStatus(code) { res.statusCode = code; return res; }
            };
            const req = { params: { id: match[1] && decodeURIComponent(match[1]) }, get: (h) => headers[h] };
            await handler(req, res);
            return res;
        }
        throw new Error('no route ' + method + ' ' + url);
    }
    return { app, call };
}

// tmux stand-in: the windows, and what each Claude's screen shows; records
// every command
function fakeTmux(windows, screens = {}) {
    const calls = [];
    const tmux = async (args) => {
        calls.push(args);
        if (args[0] === 'capture-pane') return { ok: true, stdout: screens[args[3]] || '' };
        if (args[0] === 'list-windows') {
            return { ok: true, stdout: windows.map((w) => w.join('\t')).join('\n') + '\n' };
        }
        if (args[0] === 'kill-window') {
            const i = windows.findIndex((w) => w[0] === args[2]);
            if (i >= 0) windows.splice(i, 1);
        }
        return { ok: true, stdout: '' };
    };
    return { tmux, calls };
}

const NOW = 1_800_000_000;
// id, index, name, active, activity, pane pid, command. tmux names every
// window bash (the launch command's process group leader); 3 was renamed.
const threeWindows = () => [
    ['@1', '1', 'bash', '0', String(NOW - 60), '100', 'bash', '✳ Claude Code'],
    ['@4', '2', 'bash', '1', String(NOW - 1), '200', 'bash', '⠐ Terminal update test'],
    ['@7', '3', 'build', '0', String(NOW), '300', 'bash', 'homeassistant'],
    ['@9', '4', 'bash', '0', String(NOW), '400', 'bash', 'homeassistant']
];
const proc = fakeProc(3_000_000, [
    [100, 1, 1000], [101, 100, 512000, 'claude'],   // window 1: Claude
    [200, 1, 1000], [201, 200, 2000, 'claude-session-'], [202, 201, 598000, '2.1.327'],
    [203, 202, 50000, 'rg'],                        // window 2: picker > Claude > a tool
    [300, 1, 2048],                                 // window 3: a shell, renamed
    [400, 1, 1000], [401, 400, 3000, 'claude-session-']  // window 4: the picker
]);

await test('labels: Claude or the picker found by process; a renamed window keeps its name', () => {
    const w = (name) => ({ name, command: 'bash' });
    assert.equal(windowLabel(w('bash'), { claude: true, picker: true }), 'claude');
    assert.equal(windowLabel(w('bash'), { claude: false, picker: true }), 'picker');
    assert.equal(windowLabel(w('bash'), { claude: false, picker: false }), 'bash');
    assert.equal(windowLabel(w('build'), { claude: true, picker: false }), 'build');
});

await test('conversation name: the title after its ✳ or spinner; none for the default title', () => {
    assert.equal(conversationName('✳ Terminal update test'), 'Terminal update test');
    assert.equal(conversationName('⠂ Fix the\tlights'), 'Fix the\tlights');
    assert.equal(conversationName('✳ Claude Code'), null);
    assert.equal(conversationName(''), null);
    assert.equal(conversationName('✳ ' + 'x'.repeat(200)).length, 80);
    const w = { name: 'bash', command: 'bash', title: '✳ Terminal update test' };
    assert.equal(windowLabel(w, { claude: true }), 'Terminal update test');
    assert.equal(windowLabel({ ...w, title: 'homeassistant' }, { claude: false, picker: false }), 'bash',
        'a shell\'s title (the host name) is not used');
});

await test('parse: ids, numbers, active, activity and pane pid', () => {
    const w = parseWindows(threeWindows().map((r) => r.join('\t')).join('\n'));
    assert.deepEqual(w.map((x) => [x.id, x.index, x.name, x.active, x.pid]), [
        ['@1', 1, 'bash', false, 100], ['@4', 2, 'bash', true, 200],
        ['@7', 3, 'build', false, 300], ['@9', 4, 'bash', false, 400]
    ]);
});

await test('process trees: memory of the whole tree, and Claude by name or version', () => {
    assert.equal(availableMemoryMB(proc), Math.round(3_000_000 / 1024));
    assert.deepEqual(processTrees([100, 200, 300, 400], proc), {
        100: { memoryMB: 501, claude: true, picker: false },
        200: { memoryMB: 636, claude: true, picker: true },
        300: { memoryMB: 2, claude: false, picker: false },
        400: { memoryMB: 4, claude: false, picker: true }
    });
    assert.equal(availableMemoryMB('/nonexistent'), null);
});

await test('busy Claude: "esc to interrupt" or a background shell below the input box only', () => {
    const rule = '─'.repeat(60);
    const screen = (above, mode) =>
        `${above}\n\n${rule}\n❯ \n${rule}\n  Opus 5.5 | config (main*)\n  🏠 Living room 21°C\n  ▸▸ auto mode on${mode}\n`;
    assert.equal(claudeBusy(screen('● Working…', ' · esc to interrupt')), true);
    assert.equal(claudeBusy(screen('done', ' · 1 shell · ↓ to manage')), true, 'a background shell still runs');
    assert.equal(claudeBusy(screen('done', ' · 2 shells · ↓ to manage')), true);
    assert.equal(claudeBusy(screen('done', ' (shift+tab to cycle)')), false);
    const quoted = 'The footer then shows "1 shell · ↓ to manage",\nor "esc to interrupt" while it works.';
    assert.equal(claudeBusy(screen(quoted, ' (shift+tab to cycle)')), false, 'the words in a reply just above the box do not count');
    assert.equal(claudeBusy('no box\nesc to interrupt'), true, 'no input box: the last line');
    assert.equal(claudeBusy('esc to interrupt\nno box'), false);
    assert.equal(claudeBusy(''), false);
});

await test('GET lists windows with memory, without pids or commands', async () => {
    const { app, call } = fakeApp();
    const windows = threeWindows();
    windows[2][6] = 'make';                     // window 3: a shell running make
    register(app, {
        tmux: fakeTmux(windows, {
            '@1': `${'─'.repeat(40)}\n❯\n${'─'.repeat(40)}\n  auto mode on`,
            '@4': `✻ Wibbling…\n${'─'.repeat(40)}\n❯\n${'─'.repeat(40)}\n  auto mode on · esc to interrupt`
        }).tmux,
        procDir: proc
    });
    const res = await call('GET', '/api/windows');
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body.windows.map((w) => [w.label, w.claude, w.busy]), [
        ['claude', true, false], ['Terminal update test', true, true], ['build', false, true], ['picker', false, false]
    ]);
    assert.deepEqual(res.body.windows[1], { id: '@4', index: 2, label: 'Terminal update test', active: true, claude: true, busy: true, memoryMB: 636 });

    assert.equal(res.body.memory.low, false);
    assert.equal(res.body.memory.availableMB, 2930);
});

await test('low memory is flagged below the threshold', async () => {
    const lowProc = fakeProc((LOW_MEMORY_MB - 100) * 1024, [[100, 1, 1]]);
    const { app, call } = fakeApp();
    register(app, { tmux: fakeTmux(threeWindows()).tmux, procDir: lowProc });
    assert.equal((await call('GET', '/api/windows')).body.memory.low, true);
});

await test('changes need the X-Window-Request header', async () => {
    const { app, call } = fakeApp();
    const fake = fakeTmux(threeWindows());
    register(app, { tmux: fake.tmux, procDir: proc });
    for (const url of ['/api/windows', '/api/windows/@7/select', '/api/windows/@7/close']) {
        assert.equal((await call('POST', url)).statusCode, 403, url);
    }
    assert.ok(!fake.calls.some((a) => a[0] !== 'list-windows'), 'no tmux change without the header');
});

const H = { 'X-Window-Request': '1' };

await test('new window runs the launch command in the claude session', async () => {
    const { app, call } = fakeApp();
    const fake = fakeTmux(threeWindows());
    register(app, { tmux: fake.tmux, procDir: proc, workdir: '/config' });
    assert.equal((await call('POST', '/api/windows', H)).statusCode, 200);
    assert.deepEqual(fake.calls.find((a) => a[0] === 'new-window'),
        ['new-window', '-t', '=claude:', '-c', '/config', 'bash', '-c', 'eval "$CLAUDE_LAUNCH_CMD"']);
});

await test('select and close act on the window id, never its number', async () => {
    const { app, call } = fakeApp();
    const fake = fakeTmux(threeWindows());
    register(app, { tmux: fake.tmux, procDir: proc });
    await call('POST', '/api/windows/@7/select', H);
    assert.deepEqual(fake.calls.find((a) => a[0] === 'select-window'), ['select-window', '-t', '@7']);
    const res = await call('POST', '/api/windows/@7/close', H);
    assert.deepEqual(fake.calls.find((a) => a[0] === 'kill-window'), ['kill-window', '-t', '@7']);
    assert.deepEqual(res.body.windows.map((w) => w.id), ['@1', '@4', '@9']);
});

await test('bad, unknown and stale ids are refused', async () => {
    const { app, call } = fakeApp();
    const fake = fakeTmux(threeWindows());
    register(app, { tmux: fake.tmux, procDir: proc });
    assert.equal((await call('POST', '/api/windows/3/close', H)).statusCode, 400);
    assert.equal((await call('POST', '/api/windows/@1;kill-server/close', H)).statusCode, 400);
    assert.equal((await call('POST', '/api/windows/@99/close', H)).statusCode, 404);
    assert.ok(!fake.calls.some((a) => a[0] === 'kill-window'));
});

await test('the last window is never closed', async () => {
    const { app, call } = fakeApp();
    const fake = fakeTmux([threeWindows()[0]]);
    register(app, { tmux: fake.tmux, procDir: proc });
    assert.equal((await call('POST', '/api/windows/@1/close', H)).statusCode, 409);
    assert.ok(!fake.calls.some((a) => a[0] === 'kill-window'));
});

await test('no session: 503, not a crash', async () => {
    const { app, call } = fakeApp();
    register(app, { tmux: async () => ({ ok: false, stdout: '', stderr: 'no server running' }), procDir: proc });
    assert.equal((await call('GET', '/api/windows')).statusCode, 503);
});

console.log(`\nAll ${passed} window API tests passed`);
