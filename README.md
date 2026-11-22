# Spyglass

**A floating panel for every Claude Code session on your Mac.**

Running several Claude Code sessions at once? Spyglass keeps a small always-on-top panel with one row per session: what it's doing right now, which ones need you, how much of your plan you've used. You can answer most prompts from the panel itself, and jump to the exact terminal tab for the rest.

<!-- TODO: demo GIF (record with demo/demo.sh, not real work) -->

## What it shows

- 🟢 **Working**: live activity ("Running kubectl get pods", "Editing api.ts"), `3/5 steps` on a task list, elapsed time otherwise
- 🟠 **Needs you**: permission prompts and questions float to the top with an orange outline
- ✅ **Done**: finished turns, ready for your next prompt
- **Names you recognise**: your `/rename`, else the name you gave the Cursor / VS Code tab, else Claude's own title
- **Model and context** on every row; at 85% context the row turns red, with one sound, so you can `/compact` first
- **Usage that fits your plan**: on a subscription, the header shows how much of the 5-hour and weekly limits is left and when they renew, and rows show tokens used. On an API key, rows show $. Past a limit, the header says extra usage is billed at API prices (if it's on) and rows show the $ added since. Behind a spend-capped Claude gateway, the header shows the spend
- **Hover for context**: how long it has been working or waiting, last prompt, folder and branch, model, context, tokens, and which tab it lives in
- **Compact view**: one line per session, grouped by repo; rows that need you stay full size
- **Recently ended**: sessions that ended in the last 24 hours (`/exit`, a crash, a closed terminal), with **Resume**
- **Every session shows up**, including ones started before Spyglass was installed (read from Claude Code's own session registry)

## What you can do from the panel

| Action | What Spyglass does |
|---|---|
| **Allow once / Deny** a permission prompt | answers it through Claude Code's permission hook, so it works wherever the session runs (terminal, Claude panel, JetBrains, cmux). The terminal prompt stays usable and the first answer wins; Deny stops the turn like Esc. Never "always allow" |
| **Answer a question** (single choice, up to 4 options) | presses the option's number; bigger questions point you to the terminal |
| **Switch model** (Opus, Sonnet, Haiku) | asks you to confirm, types `/model`, answers Claude Code's "Switch model?" prompt, and leaves your default model for new sessions unchanged |
| **Rename** (pencil on hover) | runs `/rename` and renames the terminal tab to match |
| **Resume** an ended session | opens a new tab in the same terminal and runs `claude --resume` in its folder |
| **Jump** (↗ or double-click) | brings that exact tab to the front |

The panel stays out of the way: it never takes focus from your editor, ✕ hides it (the menu bar icon brings it back), and it **comes back by itself** when a session newly needs you.

## Where it works

| Where the session runs | Shows in Spyglass | Jump | Allow / Deny | Model switch, rename | Question answers | Tested live |
|---|---|---|---|---|---|---|
| iTerm2 | ✅ | exact tab | ✅ | ✅ | ✅ | ✅ |
| Cursor / VS Code / Windsurf terminal | ✅ | exact tab (run `/spyglass:editor` once) | ✅ | ✅ | ✅ | ✅ |
| Terminal.app | ✅ | exact tab | ✅ | ✅ | jump there (its scripting presses Enter after every key) | ✅ |
| cmux | ✅ | brings cmux forward (it refuses outside control) | ✅ | jump there | jump there | partly: refusal confirmed |
| Claude Code panel in Cursor / VS Code | ✅ | focuses Claude in that window | ✅ | jump there | jump there | not yet |
| JetBrains IDEs | ✅ | opens the IDE | ✅ | jump there | jump there | not yet |
| Other terminals (Ghostty, Warp, kitty…) | ✅ | brings the app forward | ✅ | jump there | jump there | not yet |
| Claude desktop app (Code) | ❌ runs in the cloud or a sandboxed VM that doesn't load your plugins | — | — | — | — | ✅ |

Allow / Deny works in every host where the plugin's hooks run (sessions started before installing or updating Spyglass use keystrokes until they restart). Spyglass only shows a button where it works; elsewhere it offers a one-click jump to answer in place.

## Install

Inside Claude Code:

```
/plugin marketplace add shivanitomar9812-ship-it/spyglass
/plugin install spyglass@spyglass
```

Start a new Claude Code session and the panel appears in the top-right corner. Drag it wherever you like; it remembers.

Optional:

```
/spyglass:login on     # start the panel when you log in
/spyglass:editor       # Cursor / VS Code: jump to, type into and reopen terminal tabs (reload the window once after)
/spyglass:open         # reopen the panel if you quit it
```

Then run once:

```
/spyglass:setup        # model, context and plan usage on each row (wraps your statusline; never edits it)
/spyglass:setup tabs   # …and show Claude's session names on unnamed Cursor / VS Code tabs
```

`/spyglass:setup` feeds Spyglass the data Claude Code only gives to the statusline. It wraps whatever statusline you have, so it looks exactly as before (or adds a short one if you have none), backs up `settings.json` first, and `/spyglass:setup off` puts your original back.

**Requirements:** macOS 13+. Nothing else to install: a prebuilt universal binary is included (if it can't run, Spyglass builds itself with the Xcode Command Line Tools).

## How it works

The panel is a native SwiftUI app. It reads, once a second:

| Source | Gives |
|---|---|
| Claude Code's session registry (`~/.claude/sessions/`) | every running session, even without the plugin's hooks |
| The plugin's hooks → `~/.claude/spyglass/sessions/` | activity, task progress, permission prompts and questions, which terminal tab |
| Your statusline → `~/.claude/spyglass/stats/` | model, context, plan limits, API-price estimate |
| Session transcripts (read incrementally, in the background) | tokens used per session |
| The Cursor / VS Code extension → `~/.claude/spyglass/terminals/` | the names you gave your terminal tabs |

Permission prompts are answered through the plugin's `PermissionRequest` hook (`answer.sh`): while the panel runs, it waits for Spyglass's answer next to Claude Code's own prompt, accepts it only for the exact tool call it fingerprinted, and exits as soon as the prompt is answered anywhere.

For everything else, Spyglass types into the session's terminal: AppleScript for iTerm2 and Terminal.app, and the small editor extension for Cursor / VS Code (it matches the terminal by its shell's process ID). Everything it types is allow-listed (`/model opus|sonnet|haiku`, `/rename <one line>`, and the keys `1`–`4`, Esc, Enter), and keys are only sent while the prompt they answer is still pending.

The editor extension is a thin loader for `~/.claude/spyglass/editor-core.js`, which Spyglass refreshes on every update, so editor windows never need reloading after the first time.

**Privacy:** everything stays on your machine. No network calls, no telemetry. Spyglass's files hold session titles, the first 120 characters of your latest prompt, current tool descriptions, model and usage numbers, and terminal tab names. Session files are removed when a session ends; ended sessions are kept for 24 hours.

## Configuration

| Variable | Effect |
|---|---|
| `SPYGLASS_HOME` | Where state and the installed app live (default `~/.claude/spyglass`) |
| `SPYGLASS_DISABLE_PANEL=1` | Record state but don't launch the panel |

## Uninstall

```
/spyglass:setup off
/spyglass:login off
/plugin uninstall spyglass@spyglass
```

Run `/spyglass:setup off` first to restore your statusline. Then remove `~/.claude/spyglass`, and in Cursor / VS Code uninstall the `local.spyglass-focus` extension.

## Development

```bash
tests/run.sh                                     # regression checks: must print ALL PASSED
plugin/app/build.sh                              # native arch → plugin/bin/Spyglass
plugin/app/build.sh plugin/bin/Spyglass --universal
scripts/release.sh <version> "<subject>"         # tests → build → bump → push → plugin update → installed == running
```

[HARNESS.md](HARNESS.md) explains the checks and lists every bug that escaped them; [CHANGELOG.md](CHANGELOG.md) has the release history.

## License

MIT
