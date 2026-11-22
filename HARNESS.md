# Harness

How Spyglass is checked before it ships, and how the checks grow.

## Run

```bash
tests/run.sh                                   # every suite; must print ALL PASSED
scripts/release.sh 0.10.0 "Subject" ["Body"]   # tests -> universal build -> bump -> push -> plugin update -> installed == running
```

| Suite | Checks |
|---|---|
| `tests/record_test.sh` | hook input → session file (status, permission, titles, ended) |
| `tests/send_test.sh` | allow-lists, stale-prompt guards, `/model` with and without Claude Code's "Switch model?" dialog, default model left alone, rename |
| `tests/resume_test.sh` | bad ids and missing folders refused |
| `tests/setup_test.sh` | `/spyglass:setup` in a fake home: wraps without editing, output unchanged, feeds Spyglass, idempotent, `off` restores exactly, manual setups left alone, editor settings with comments untouched |
| `tests/answer_test.sh` | permission answers through the hook: fingerprint match, allow, deny (interrupt), wrong fingerprint ignored, exits when resolved elsewhere, no waiting without the panel |
| `tests/core_test.js` | Cursor / VS Code side against a stand-in API: typing, keys, tab rename, tab names, hot reload, resume |
| `tests/panel_test.sh` | `Spyglass --selftest` row logic on fixtures (names, states, tokens, plan limits, questions, compact layout, panel coming back, hover text; `--twice` reloads after fixtures change); renders `tests/out/panel.png` and `panel-compact.png` |

## Rules the tests encode

- Scripts the panel runs are tested **under launchd's PATH** (`launchd` helper in `tests/lib.sh`), never from a shell.
- No dependencies: plugin scripts never call `jq` or `perl` (`record_test.sh` greps for it); JSON goes through `Spyglass json …`. The statusline wrapper still puts Homebrew on PATH, but only for *your* statusline, which may use it.
- `send.sh` is tested through `SPYGLASS_SEND_LOG` with a fake Claude that behaves like the real one (writes the transcript, saves the default model, asks "Switch model?" when the conversation is cached).
- Don't use `.help` (macOS hides tooltips of inactive apps); use `.tip`.
- UI changes are not shipped without looking at `tests/out/panel.png`. `--state` sets click-only UI state (e.g. a model confirm card).
- Background jobs in tests: `wait <pid>`, never a bare `wait` (fixture processes sleep for minutes).
- Build JSON fixtures with `jq -n --arg` (tests may use jq; the plugin may not), never by nesting quotes in shell.
- Capture `$?` on its own line, right after the command: not inside a string with other `$(...)`, not after a pipe.
- The README GIF is rendered from fake sessions (`demo/storyboard.sh`); look at its frames as a contact sheet before shipping, it is a UI review too.
- Live Claude Code checks run in a throwaway session in its **own** window (iTerm2 or Terminal), addressed by tty only, driven only through `send.sh` — never by typing commands by hand.
- cmux refuses control from processes outside cmux (no socket password set); test cmux only by its jump.

## Facts established by live experiments

Claude Code 2.1.330, `PermissionRequest` hook (2026-11-22):
- The terminal prompt shows while the hook is still running; the hook never blocks the person.
- The hook's `{"decision":{"behavior":"allow"}}` closes the terminal prompt and runs the tool; `deny` with `"interrupt":true` stops the turn exactly like Esc.
- First answer wins: a later hook answer is ignored; a hook still waiting is not stopped by Claude Code, so `answer.sh` watches the session file and exits.
- Claude Code may auto-approve a repeat of a command already approved in that session about 2 s after showing the prompt: live tests must use a command the session hasn't seen.

## The loop

1. A bug reaches the user → add a check that fails on it, then fix it, then add a line below.
2. After each feature, note what the harness missed or made slow, and improve the harness before the next feature.

## Escaped bugs

| Version | Bug | Missing check → now |
|---|---|---|
| 0.6.1 | Cursor model switch silently failed: `jq` not on launchd's PATH | scripts tested from a shell → all script tests run under launchd PATH |
| 0.8.0 | Default model overwritten after confirming "Switch model?" | tests used fresh sessions only → fake Claude with dialog in `send_test.sh` |
| 0.9.0 | Claude Code's idle reminder showed as "Needs you" | no hook fixtures → `record_test.sh`, `panel_test.sh` |
| 0.9.0 | "2.1.330" (Claude Code's process title) taken as a tab name | no panel logic tests → `panel_test.sh` |
| 0.7.0 | Cursor kept running stale extension code | nothing checked what Cursor loaded → hot-loaded core, `core_test.js` hot-reload check |
| 0.5.0 | A local build was swapped out by the installed plugin | no installed-vs-running check → `release.sh` compares every file |
| 0.12.0 | Hover text never appeared: macOS shows `.help` tooltips only for the active app, and Spyglass's panel never activates | tests checked the text, not that macOS shows it → Spyglass draws its own hover card (`TipCenter`); `.help` is not used. Behaviour that depends on macOS (focus, tooltips, menus) needs a live look, not just a snapshot |
| 0.12.1 (local) | Hover card showed ~1000 pt from the pointer: measured with no width, it wrapped into a very tall window | `panel_test.sh` checks card sizes from `TipCenter.measure` |
| 0.12.1 | Release left the personal GitHub account active: another session had switched it, and the script "restored" that | `release.sh` uses the account's token (`GH_TOKEN`) for its own commands and never runs `gh auth switch` |
| — | Buttons appeared in hosts where typing can't work (Claude panel, desktop app, JetBrains, cmux) and failed with ⚠︎ | per-session `Caps`; `panel_test.sh` host matrix; `send_test.sh` routing |
| — | Terminal.app `do script` presses Enter after every key: a test drifted from a dialog into settings and vim (found live) | Terminal.app gets text commands only; keys route to "Answer in Terminal ↗"; never type exploratory commands into test sessions |
| 0.13.0 | README claimed Claude desktop app sessions show in Spyglass; a live test showed they run in the cloud or a sandboxed VM that ignores local plugins (no hooks, no process, no transcript on the Mac) | support claims need a live session per host before they ship; untested hosts are marked untested |
| 0.16.0 | Names showed Claude Code's status symbol ("✳ TTD channel…") once Cursor tabs show Claude's title | `panel_test.sh` fixture tab name starts with "✳ " |
| 0.20.0 | Yes / No missing when the question followed a statement (yes/no judged on the first word; found rendering the demo GIF) | `panel_test.sh` "yes/no judged on the asking sentence" |
| 0.20.0 (local) | A reply arrived as "yesyes": text already typed in Claude's input merged with Spyglass's "yes" (reported by the user; one send, confirmed by the claim log) | text sends clear the input first (Ctrl-U / Backspace); `core_test.js` checks the clear prefix, and keys stay unprefixed |
| 0.19.0 | A plain-text question didn't pop up in sessions running hooks older than 0.18 (every long-running session; reported by the user) | the panel also reads the question from the transcript; `panel_test.sh` old-hooks checks |
| 0.18.0 | Collapsed, the "done" chime played but nothing showed which session rang (reported by the user) | collapsed header lists sessions that need you and ones that just finished; `panel_test.sh` peek check |
| 0.17.0 | A question asked in plain text at the end of a turn showed as Done (no hook flags it; reported by the user) | Stop hook reads `last_assistant_message`; `record_test.sh` covers question / plain / code-block endings |
| — | Snapshots used the user's saved panel settings (collapsed) | test mode pins collapsed, muted, compact and welcome; `--state` sets them |
| 0.17.0 (caught) | Dropping Homebrew from the statusline wrapper's PATH broke the user's own statusline (it uses jq) | `setup_test.sh` "your statusline shows as before" runs a jq-using statusline under launchd PATH |
| — | Panel tests ran a binary built before the rename: it ignored the test fixtures and read the real session state (found while renaming to Spyglass) | `panel_test.sh` rebuilds when the Swift source is newer than the binary |
| — | `record.sh` / `stats.sh` lacked the Homebrew PATH line (found by the harness's first run) | `record_test.sh` runs under launchd PATH |
| — | Status line truncated the context warning ("⚠︎ ct…") (found in the first snapshot) | look at `panel.png` before shipping UI; warning has top layout priority |
| — | Claude's questions arrive as a *permission* request: "Allow once" (key 1) would silently pick option 1 (found in a live check) | `record_test.sh` question cases; panel never shows Allow/Deny for AskUserQuestion |
| — | The model menu can't be drawn offscreen (yellow 🚫 in snapshots) | `Store.snapshotMode` draws a plain stand-in |
| — | "$0.00 extra" squeezed a row's status word to "W" (found in the over-limit snapshot) | extra $ shown only once > $0.01 |
| — | "Bring the panel back" missed sessions already waiting at startup: the Store's first reload ran before the handler was set (found by the new test) | `panel_test.sh` wake check |

## Not yet checked live

Covered by fixture tests only; each needs one live session before the README can say "tested":

- The Claude Code panel in Cursor / VS Code: jump focuses Claude in the right window
- JetBrains IDEs (terminal and plugin): detection, jump
- cmux: jump to a real cmux session (control refusal is confirmed)
- Ghostty, Warp, kitty and other terminals: detection, jump
- The panel coming back on its own when a session needs you (logic tested; the window appearing was not watched)
- CI (`.github/workflows/ci.yml`) runs on GitHub's macOS runners: the first run is its live check
