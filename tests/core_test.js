// The Cursor / VS Code side: loader (extension.js) + hot-loaded core (core.js), against a stand-in vscode API.
const fs = require('fs'), os = require('os'), path = require('path'), Module = require('module');
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'spyglass-core-'));
process.env.HOME = home;
process.env.NODE_PATH = path.join(__dirname, 'fixtures', 'node_modules'); Module._initPaths();
const root = path.join(__dirname, '..', 'plugin', 'editor-extension');
const dir = path.join(home, '.claude', 'spyglass'); fs.mkdirSync(dir, { recursive: true });
const corePath = path.join(dir, 'editor-core.js');
fs.copyFileSync(path.join(root, 'core.js'), corePath);
const vscode = require('vscode'); const log = vscode.__log;
const ext = require(path.join(root, 'extension.js'));
const subs = []; ext.activate({ subscriptions: subs });

let pass = 0, fail = 0;
const eq = (name, want, got) => { const a = JSON.stringify(want), b = JSON.stringify(got);
  if (a === b) pass++; else { fail++; console.log(`  FAIL ${name}\n    expected: ${a}\n    actual:   ${b}`); } };
const wait = ms => new Promise(r => setTimeout(r, ms));
const write = (name, o) => fs.writeFileSync(path.join(dir, name), JSON.stringify({ ts: Date.now() / 1000 + Math.random() / 1000, ...o }));
const read = name => { try { return JSON.parse(fs.readFileSync(path.join(dir, name), 'utf8')); } catch { return null; } };
const send = async (text, shellPid = 4242) => { log.length = 0; write('send-request.json', { shellPid, text }); await wait(900); return read('send-response.json'); };
const sent = () => log.filter(x => x[0] === 'send').map(x => x[2]);

(async () => {
  await wait(300);
  let r = await send('/model haiku');
  eq('model typed, Enter separate', ['/model haiku', '\r'], sent()); eq('model ok', true, r.ok);
  for (const bad of ['rm -rf ~', '/model gpt', 'constructor', '/rename a\nb', '/rename x\u001b[2J']) {
    r = await send(bad); eq(`refused ${JSON.stringify(bad)}`, [false, []], [r.ok, sent()]);
  }
  await send('key:approve'); eq('approve = 1', ['1'], sent());
  await send('key:deny'); eq('deny = Esc', ['\u001b'], sent());
  await send('key:enter'); eq('enter', ['\r'], sent());
  await send('key:2'); eq('question option 2', ['2'], sent());
  // Two loaders in one window (old + new extension until it reloads): a request is typed once.
  { const core = require(corePath); const st2 = {}; log.length = 0;
    write('send-request.json', { shellPid: 4242, text: 'key:1' }); await wait(900);
    await core.send(vscode, st2);
    eq('second loader does not type again', ['1'], sent()); }
  r = await send('key:9'); eq('key:9 refused', false, r.ok);
  await send('/model opus', 9999); eq('other window ignores', [], sent());
  r = await send('/rename Seg Lifecycle'); eq('rename typed', ['/rename Seg Lifecycle', '\r'], sent());
  r = await send('tabname:Seg Lifecycle');
  eq('tab renamed, previous terminal active again', ['Seg Lifecycle', 5555, true],
     [vscode.window.terminals[0].name, vscode.window.activeTerminal.pid, r.ok]);
  r = await send('tabname:bad\nname'); eq('bad tab name refused', false, r.ok);
  // Claude extension panel: only the window that has the session's folder open focuses Claude's input.
  log.length = 0; write('focus-request.json', { claudePanel: true, cwd: '/ws/sub' }); await wait(900);
  eq('panel session: focus Claude in its window', [['cmd', 'claude-vscode.focus', undefined]], log.filter(x => x[0] === 'cmd'));
  log.length = 0; write('focus-request.json', { claudePanel: true, cwd: '/elsewhere' }); await wait(900);
  eq('panel session in another window: ignored', [], log.filter(x => x[0] === 'cmd'));
  // Tab names are published for Spyglass.
  // Published every 3 s: wait for the renamed tab to show up.
  let pub = null;
  for (let i = 0; i < 40; i++) {
    const files = fs.readdirSync(path.join(dir, 'terminals'));
    pub = JSON.parse(fs.readFileSync(path.join(dir, 'terminals', files[0]), 'utf8'));
    if (pub.rows[0].name === 'Seg Lifecycle') break;
    await wait(100);
  }
  eq('tab names published', [4242, 'Seg Lifecycle'], [pub.rows[0].pid, pub.rows[0].name]);
  // Hot reload: a new core on disk is used by the next request, no window reload.
  fs.writeFileSync(corePath, fs.readFileSync(corePath, 'utf8').replaceAll('core: true', 'core: "v2"'));
  r = await send('/model sonnet'); eq('hot-reloaded core', 'v2', r.core);
  // Resume opens a terminal in the folder (focused window only).
  log.length = 0; write('resume-request.json', { cwd: os.tmpdir(), id: '11111111-2222-3333-4444-555555555555' }); await wait(900);
  eq('resume', [['create', os.tmpdir()], ['send', 7777, 'claude --resume 11111111-2222-3333-4444-555555555555', true]],
     log.filter(x => x[0] === 'create' || x[0] === 'send'));
  write('resume-request.json', { cwd: '/tmp', id: 'x; rm -rf ~' }); await wait(900); eq('resume bad id refused', false, read('resume-response.json').ok);

  subs.forEach(s => s.dispose()); clearInterval(globalThis.__spyglassTabNames && globalThis.__spyglassTabNames.timer);
  fs.rmSync(home, { recursive: true, force: true });
  console.log(`core_test: ${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
})();
