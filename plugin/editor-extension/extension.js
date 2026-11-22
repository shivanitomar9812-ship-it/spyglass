// Spyglass Focus: thin loader. Watches ~/.claude/spyglass/{focus,send,resume}-request.json and hands each to
// ~/.claude/spyglass/editor-core.js (installed by Spyglass), re-reading the core whenever it changes,
// so Spyglass updates never need a window reload.
const vscode = require('vscode');
const fs = require('fs');
const path = require('path');
const os = require('os');

const dir = path.join(os.homedir(), '.claude', 'spyglass');
const corePath = path.join(dir, 'editor-core.js');
const state = {};   // per-window state that survives core reloads
let core = null;
let coreMtime = 0;

function loadCore() {
  try {
    const mtime = fs.statSync(corePath).mtimeMs;
    if (!core || mtime !== coreMtime) {
      delete require.cache[require.resolve(corePath)];
      core = require(corePath);
      coreMtime = mtime;
    }
  } catch (e) {
    core = null;
    console.error('[spyglass-focus] cannot load', corePath, e && e.message);
  }
  return core;
}

function run(kind) {
  return () => {
    const c = loadCore();
    if (c && typeof c[kind] === 'function') {
      Promise.resolve(c[kind](vscode, state)).catch(e => console.error('[spyglass-focus]', kind, e && e.message));
    }
  };
}

function activate(context) {
  fs.mkdirSync(dir, { recursive: true });
  const watched = { focus: 'focus-request.json', send: 'send-request.json', resume: 'resume-request.json' };
  for (const [kind, name] of Object.entries(watched)) {
    const f = path.join(dir, name);
    const h = run(kind);
    fs.watchFile(f, { interval: 250 }, h);
    context.subscriptions.push({ dispose: () => fs.unwatchFile(f, h) });
  }
  // A resume request may arrive just before this window gains focus.
  context.subscriptions.push(vscode.window.onDidChangeWindowState(s => { if (s.focused) run('resume')(); }));
}

module.exports = { activate, deactivate() {} };
