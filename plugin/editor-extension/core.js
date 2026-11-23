// Spyglass editor core: copied to ~/.claude/spyglass/editor-core.js by launch.sh and hot-loaded by the
// spyglass-focus extension, so Spyglass updates reach Cursor / VS Code without reloading the window.
// Each handler gets (vscode, state); state survives core reloads.
const fs = require('fs');
const path = require('path');
const os = require('os');

const dir = path.join(os.homedir(), '.claude', 'spyglass');
const file = name => path.join(dir, name);
const ALLOWED = /^\/(model (opus|sonnet|haiku)|remote-control)$/;
const NAME = '[^\\x00-\\x1f\\x7f]{1,80}';   // one line, no control characters
const RENAME = new RegExp(`^/rename ${NAME}$`);
const TAB_NAME = new RegExp(`^${NAME}$`);
// Before typing text, clear whatever is half-typed in Claude's input (up to 4 lines; harmless when empty).
const CLEAR = '\x15\x7f\x15\x7f\x15\x7f\x15';
const SAY = /^(?!\/)(?! )[^\x00-\x1f\x7f]{1,1500}$/;   // replies: one line, not a slash command
// Permission prompt answers: "1" picks "Yes" (never "always allow"); Esc declines. send.sh checks the prompt is still pending.
// Enter confirms the highlighted option (Claude Code's "Switch model?" dialog, after the user confirmed in Spyglass).
// key:1-4 pick an option of Claude's question (send.sh checks it is still pending).
const KEYS = { 'key:approve': '1', 'key:deny': '\x1b', 'key:enter': '\r', 'key:1': '1', 'key:2': '2', 'key:3': '3', 'key:4': '4' };
const SESSION_ID = /^[0-9a-fA-F-]{36}$/;

function read(name) {
  try { return JSON.parse(fs.readFileSync(file(name), 'utf8')); } catch { return null; }
}
const fresh = req => req && req.ts && Date.now() / 1000 - req.ts <= 10;

// Claim a request so only one loader acts on it: after a rename or reinstall, the old and new extension can both be
// running in one window until it reloads, and must not type twice. mkdir is atomic: the first claimer wins.
function claim(kind, req) {
  const d = path.join(dir, 'claims');
  try { fs.mkdirSync(d, { recursive: true }); } catch {}
  try { fs.mkdirSync(path.join(d, `${kind}-${req.ts}`)); } catch { return false; }
  try {   // tidy claims older than a minute
    for (const n of fs.readdirSync(d)) { const t = parseFloat(n.split('-').pop()); if (Date.now() / 1000 - t > 60) fs.rmSync(path.join(d, n), { recursive: true, force: true }); }
  } catch {}
  return true;
}

// Tab names: each window writes terminals/<ext host pid>.json every few seconds ({ts, rows: [{pid, name}]}, pid = shell pid),
// so Spyglass can show the names you gave Cursor tabs. Read-only. The timer is replaced when a new core loads.
const LOAD = {};
function publishTabNames(vscode) {
  const g = globalThis.__spyglassTabNames || (globalThis.__spyglassTabNames = {});
  if (g.load === LOAD) return;
  clearInterval(g.timer);
  g.load = LOAD;
  const out = path.join(dir, 'terminals', `${process.pid}.json`);
  const write = async () => {
    const rows = [];
    for (const t of vscode.window.terminals) rows.push({ pid: await t.processId, name: t.name });
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out + '.tmp', JSON.stringify({ ts: Date.now() / 1000, rows }));
    fs.renameSync(out + '.tmp', out);
  };
  g.timer = setInterval(() => write().catch(() => {}), 3000);
  write().catch(() => {});
}

async function findTerminal(vscode, shellPid) {
  for (const t of vscode.window.terminals) {
    if ((await t.processId) === shellPid) return t;
  }
  return null;
}

// Show the terminal whose shell is the session's parent.
async function focus(vscode, st) {
  publishTabNames(vscode);
  const req = read('focus-request.json');
  if (!fresh(req) || req.ts === st.focusTs) return;
  if (req.claudePanel) {
    // A session in the Claude Code extension panel: the window whose folder holds its cwd focuses Claude's input.
    const folders = (vscode.workspace.workspaceFolders || []).map(f => f.uri.fsPath);
    const owns = typeof req.cwd === 'string' && folders.some(f => req.cwd === f || req.cwd.startsWith(f + path.sep));
    if (!owns) return;
    st.focusTs = req.ts;
    if (!claim('focus', req)) return;
    await vscode.commands.executeCommand('claude-vscode.focus');
    const target = vscode.workspace.workspaceFile?.fsPath || folders[0] || '';
    fs.writeFileSync(file('focus-response.json'), JSON.stringify({ ts: req.ts, target }));
    return;
  }
  const t = await findTerminal(vscode, req.shellPid);
  if (!t) return;   // another window owns it
  st.focusTs = req.ts;
  if (!claim('focus', req)) return;
  t.show(false);
  await vscode.commands.executeCommand('workbench.action.terminal.focus');
  const target = vscode.workspace.workspaceFile?.fsPath || vscode.workspace.workspaceFolders?.[0]?.uri.fsPath || '';
  fs.writeFileSync(file('focus-response.json'), JSON.stringify({ ts: req.ts, target }));
}

// Type an allow-listed command or key into that terminal.
async function send(vscode, st) {
  publishTabNames(vscode);
  const req = read('send-request.json');
  if (!fresh(req) || req.ts === st.sendTs) return;
  if (req.text === 'list:terminals') { publishTabNames(vscode); return; }   // Spyglass's wake-up ping after a window reload
  const t = await findTerminal(vscode, req.shellPid);
  if (!t) return;
  st.sendTs = req.ts;
  if (!claim('send', req)) return;
  if (typeof req.text === 'string' && req.text.startsWith('tabname:')) {
    // Rename this terminal's tab: Cursor only renames the active terminal, so switch to it and back.
    const name = req.text.slice('tabname:'.length);
    const ok = TAB_NAME.test(name);
    if (ok) {
      const prev = vscode.window.activeTerminal;
      t.show(true);
      await vscode.commands.executeCommand('workbench.action.terminal.renameWithArg', { name });
      if (prev && prev !== t) prev.show(true);
    }
    fs.writeFileSync(file('send-response.json'), JSON.stringify({ ts: req.ts, ok, core: true }));
    return;
  }
  if (typeof req.text === 'string' && req.text.startsWith('say:')) {
    // A reply to a question Claude asked in text: one line, no control characters; typed, then Enter.
    const text = req.text.slice('say:'.length);
    const ok = SAY.test(text);
    if (ok) { t.sendText(CLEAR + text, false); await new Promise(r => setTimeout(r, 300)); t.sendText('\r', false); }
    fs.writeFileSync(file('send-response.json'), JSON.stringify({ ts: req.ts, ok, core: true }));
    return;
  }
  const key = Object.hasOwn(KEYS, req.text) ? KEYS[req.text] : null;
  const ok = !!key || (typeof req.text === 'string' && (ALLOWED.test(req.text) || RENAME.test(req.text)));
  if (key) {
    t.sendText(key, false);
  } else if (ok) {
    // Text and Enter go separately so Claude Code doesn't take it as a paste.
    t.sendText(CLEAR + req.text, false);
    await new Promise(r => setTimeout(r, 300));
    t.sendText('\r', false);
  }
  fs.writeFileSync(file('send-response.json'), JSON.stringify({ ts: req.ts, ok, core: true }));
}

// Resume an ended session: only the focused window acts (resume.sh brings the editor to the front first).
async function resume(vscode, st) {
  publishTabNames(vscode);
  const req = read('resume-request.json');
  if (!fresh(req) || req.ts === st.resumeTs || !vscode.window.state.focused) return;
  st.resumeTs = req.ts;
  if (!claim('resume', req)) return;
  const ok = typeof req.id === 'string' && SESSION_ID.test(req.id) && typeof req.cwd === 'string' && fs.existsSync(req.cwd);
  if (ok) {
    const t = vscode.window.createTerminal({ cwd: req.cwd, name: 'claude' });
    t.show(false);
    t.sendText(`claude --resume ${req.id}`, true);
  }
  fs.writeFileSync(file('resume-response.json'), JSON.stringify({ ts: req.ts, ok }));
}

module.exports = { focus, send, resume };
