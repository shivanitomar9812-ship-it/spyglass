# Security

Spyglass watches your Claude Code sessions and can act on them (approve a tool call, type a reply). This page says exactly what it trusts, what it types, and what it never does.

## What stays where

- **No network, unless you set up away mode.** Spyglass makes no network calls and sends no telemetry. The one exception is away mode (below), which is off until you run `/spyglass:away setup`: it then talks to Telegram's Bot API (`api.telegram.org`) and nowhere else.
- **Local files only.** It reads Claude Code's session registry (`~/.claude/sessions/`) and transcripts (`~/.claude/projects/`), and keeps its own state in `~/.claude/spyglass/`: session titles, the first 120 characters of your latest prompt, current tool descriptions, model and usage numbers, terminal tab names. Session files are removed when a session ends; ended sessions are kept for 24 hours.

## What it can do to a session

| Action | How | Limits |
|---|---|---|
| Allow once / Deny a permission prompt | answers Claude Code's `PermissionRequest` hook with allow / deny | only for the prompt whose tool call matches the fingerprint the hook recorded; never "always allow"; the first answer wins, so a stale click is ignored. Risky commands (recursive delete, `sudo`, pushes and publishing, production hosts, cluster / cloud / infrastructure changes, SQL writes and migrations, `curl \| sh`; the full list is `Risk.rules` in `plugin/app/Model.swift`) can't be allowed from the panel: the panel shows no Allow, and the hook refuses an allow for them even if one is written to its answers folder; Deny still works. With ⚙ → Allow from the panel turned off (`~/.claude/spyglass/panel-allow-off`), no prompt can be allowed from the panel, and the hook refuses every allow. You can add your own rules in `~/.claude/spyglass/risky.txt` (⚙ → Risky commands…): plain text or `re:` patterns, matched against the command, or the file / URL for other tools. A `!name` line there turns off one built-in rule by the name the card shows |
| Allow once / Deny from your phone (away mode) | a Telegram bot chat you set up; the panel sends a message when a session needs you and polls for the button press | off until set up and switched on (header phone button, `Spyglass away on`, or automatically on screen lock / idle if `auto` is on). Only the one chat id in `away.json` is believed (anything else is ignored silently). A button works only for the prompt it was sent for (fingerprint), for one hour, and never for a risky command or while Allow from the panel is off; it goes through the same answer file and hook checks as the panel, which refuse those cases again. Deny always works. Sent: session name, folder, and the command / path / URL (300 characters), or the question or last line; never tool output, file contents or transcripts. Questions and plain-text asks arrive without buttons: answer them at the Mac |
| Pick an option of Claude's question | presses its number | only while that same question is pending |
| Reply to a question asked in text | types one line and Enter | only while the session waits on you with no prompt or question open; one line, no control characters, never a `/` command |
| Switch model / rename | types `/model opus\|sonnet\|haiku` or `/rename <one line>` | allow-listed exactly; idle sessions only; your default model is restored afterwards |
| Resume | opens a terminal tab and runs `claude --resume <id>` in the session's folder | the id must be a session id; the folder must exist |

Everything typed is allow-listed twice: by `plugin/scripts/send.sh` and again by the editor extension's core (`plugin/editor-extension/core.js`). Before typing text, Spyglass clears whatever is half-typed in Claude's input so the two can't merge.

## Away mode and the bot token

`~/.claude/spyglass/away.json` (mode 600) holds the Telegram bot token and your chat id. `Spyglass away setup` reads the token without echo in your own terminal: don't paste it into a Claude session, where it would become part of the conversation. Anyone with the token can read what Spyglass sends and, by messaging the bot, nothing more: only your chat id is accepted for answers, and the bot can be revoked any time in @BotFather (/revoke). Telegram bot chats are not end-to-end encrypted, so the messages (a command line, a question) are visible to Telegram. Don't turn on away mode if that is not acceptable for your commands.

## The trust boundary

Spyglass trusts files in `~/.claude/spyglass/`: the panel and the editor extension communicate through request files there, and the permission hook accepts answers from `~/.claude/spyglass/answers/`. **Anything that can write to that folder as you can approve a pending permission prompt or have text typed into a session.** That is the same as anything else running as your user, which could already type into your terminals; but note that Claude Code's sandbox should not be configured to allow writes there.

macOS asks once for permission to let Spyglass control iTerm2 or Terminal (AppleScript). The Cursor / VS Code extension only acts on terminals in its own window, matched by the shell's process ID.

## The binary

`plugin/bin/Spyglass` is a universal macOS binary built from the Swift sources in `plugin/app/` by `scripts/release.sh`, after the full test suite passes. CI builds the same source on every push and attaches its build and SHA-256 to each GitHub release. To run only what you built yourself:

```bash
plugin/app/build.sh plugin/bin/Spyglass --universal
```

or set `SPYGLASS_BUILD_FROM_SOURCE=1` and the plugin builds the binary on your Mac (needs the Xcode Command Line Tools).

## Reporting a problem

Please use GitHub's **private vulnerability reporting** on this repository (Security → Report a vulnerability) rather than a public issue.
