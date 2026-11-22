# Changelog

All releases so far were made on 2026-11-22. Versions before 0.16.0 were released under the name Tower. Bugs that escaped to a release, and the check that now catches each, are in [HARNESS.md](HARNESS.md).

## 0.20.4
- Fixed: since 0.17.0, sessions started with the installed plugin lost their activity, prompts, questions and permission answers within a second. The hook took its own process (its path is under `~/.claude`) for Claude's, and the panel then dropped the row as ended. Spyglass now finds each session's process in Claude Code's own session registry.

## 0.20.3
- The binary finds your home folder through `$HOME`, like the plugin's scripts, so both always agree on where Spyglass keeps its state.

## 0.20.2
- Collapsed, click a **Needs you** line to open that session's full row in place (the question with Yes / No / Reply…, or the command with Allow once / Deny) and answer without expanding the panel; ⌃ folds it back, and it folds by itself once answered. ↗ still jumps.
- Rows name known apps (Cursor, VS Code, iTerm2…) even where macOS can't look them up.

## 0.20.1
- Yes / No now appear when the question follows a statement ("The docs are ready. Should I also…?"); it used to judge the first word only.
- `SECURITY.md`: what Spyglass trusts, what it can type, and the trust boundary. `SPYGLASS_BUILD_FROM_SOURCE=1` builds the binary on your Mac.
- CI tests every push on macOS and attaches its own universal build (with SHA-256) to each release.
- README: demo GIF (rendered from fake sessions by `demo/storyboard.sh`), test badge, Troubleshooting.

## 0.20.0
- Reply from the panel: a question Claude asks in text gets **Yes / No** (for yes/no questions) and **Reply…** (one line, Enter sends). Spyglass types it only while the session waits on you with nothing else open, only where it can type, and never a slash command.
- Before typing text (a reply, `/model`, `/rename`), Spyglass clears anything half-typed in Claude's input, so a draft can't merge with it.
- Click a row to jump there (was double-click).
- ⚙ settings: chime when a session finishes, ping when one needs you, come back when one needs you, compact view, start at login, show welcome.
- Rows on hooks older than the installed Spyglass show ↻: restart them (`claude --resume`) for the newest features.
- Finished rows preview the last line of Claude's reply.

## 0.19.1
- A question at the end of a turn now pops up in every session, including ones running older hooks: the panel also reads it from the transcript.

## 0.19.0
- Collapsed, the panel lists the sessions that need you and the ones that just finished (the chime), one line each with why ("Needs you", "Done · 2m"); click to jump. A finished session drops off once you jump to it, give it a new prompt, or after 15 minutes.

## 0.18.0
- A turn that ends by asking you something in plain text ("Shall I go ahead?") now shows as **Needs you**, with the question on the row and a jump to reply. It used to show as Done.
- First-run welcome card: what Spyglass is, and a setup checklist that ticks itself off (`/spyglass:setup`, the editor extension, the macOS permission note). "Show welcome" in the menu bar brings it back.

## 0.17.0
- No dependencies: `jq` is no longer needed. The hooks (`record`, `answer`, `stats`) run inside the Spyglass binary, and the scripts use its small JSON helper. Hooks are also faster (about 12 ms per event, from 22 ms).
- The JSON helper refuses to change a settings file that isn't plain JSON, so a file with comments is never overwritten.

## 0.16.1
- Names no longer start with Claude Code's status symbol ("✳ ") taken from editor tab titles.

## 0.16.0
- Renamed from Tower to Spyglass ("Tower" is also a well-known Git client for Mac). Existing installs move automatically: `~/.claude/tower` becomes `~/.claude/spyglass` (the old path stays as a link), panel preferences and the login item carry over, and the editor extension is now `local.spyglass-focus`.
- The editor core claims each request once, so an old and a new extension running side by side never type twice.

## 0.15.0
- `/spyglass:setup`: one command for model, context and plan usage. It wraps your statusline instead of editing it (or adds a short one), backs up `settings.json`, does nothing if you're already set up, and `/spyglass:setup off` restores the original.
- `/spyglass:setup tabs` also shows Claude's session names on unnamed Cursor / VS Code / Windsurf tabs; settings files with comments are left untouched.

## 0.14.0
- Allow / Deny answer permission prompts through Claude Code's `PermissionRequest` hook instead of keystrokes, so they work in every host where hooks run: Terminal.app, the Claude panel, JetBrains, cmux, any terminal.
- The terminal prompt stays usable while Spyglass waits; the first answer wins, and Deny stops the turn like Esc.
- Sessions with older hooks fall back to keystrokes where possible.

## 0.13.0
- Works wherever Claude runs: each session gets capabilities from where it runs (iTerm2, Cursor / VS Code terminal, Terminal.app, the Claude Code panel, JetBrains, cmux).
- Terminal.app: model switch and rename. Allow / Deny and answers show "Answer in Terminal ↗", since its scripting presses Enter after every key.
- The Claude panel, JetBrains and cmux get a jump to answer in place instead of buttons that can't work.
- Support table corrected after release: Claude desktop app sessions aren't visible (cloud or sandboxed VM, no local hooks).

## 0.12.1
- Spyglass draws its own hover cards: macOS hides standard tooltips for apps that aren't active, and Spyglass's panel never activates.
- Cards are measured at their real width, so they sit next to the pointer.
- Releases push with a token instead of switching the shared `gh` account.

## 0.12.0
- Hover a row, the context %, the status word or ↗ for details: time in state, last prompt, folder and branch, model, context tokens, usage, tab.

## 0.11.0
- Past a 5-hour or weekly limit: a header warning, and rows show the $ added since crossing (extra usage is billed at API prices if it's on).
- Behind a spend-capped Claude gateway: the header shows the spend, rows show $.

## 0.10.1
- A hidden panel comes back when a session newly needs you.

## 0.10.0
- Regression checks (`tests/run.sh`) and a release gate (`scripts/release.sh`).
- Plan usage: 5-hour and weekly limits left in the header; tokens instead of $ on subscriptions.
- Answer Claude's multiple-choice questions from the row.
- Compact view, grouped by repo.

## 0.9.0
- Rename a session from the panel: `/rename` plus the terminal tab.
- Claude Code's one-minute idle reminder no longer shows as "Needs you"; version-like tab names ("2.1.330") are ignored.

## 0.8.0
- Confirm model switches in the panel; Spyglass answers Claude Code's "Switch model?" prompt and keeps your default model.
- Rows use the names you gave your Cursor / VS Code tabs.

## 0.7.0
- The editor extension hot-loads its logic from `~/.claude/spyglass`, so updates need no window reload.

## 0.6.1
- Fixed: actions in Cursor failed because `jq` wasn't on launchd's PATH.

## 0.6.0
- Context warning at 85%.

## 0.5.0
- Recently ended sessions with Resume.
- Fixed: a binary update could leave the panel stopped.

## 0.4.0
- Allow once / Deny for permission prompts.

## 0.3.0
- Model switcher on each row.
- Model, context % and cost on each row (from the statusline).

## 0.2.0
- Every running session shows up, from Claude Code's session registry; the panel no longer quits on its own.

## 0.1.0
- First release: a floating panel listing running Claude Code sessions, with jump-to-tab.
