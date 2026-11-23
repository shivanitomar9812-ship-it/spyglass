---
description: Away mode: send what needs you to your phone (Telegram) and answer Allow / Deny from there
allowed-tools: Bash(bash:*)
---

Away mode sends permission prompts, questions and (optionally) finished sessions to a private Telegram chat while you're away from the Mac. Allow once / Deny buttons there answer prompts; risky commands only get Deny. Only the chat you set up can answer.

Based on the argument `$ARGUMENTS`:

- **setup** (or nothing, and Spyglass isn't set up): do NOT ask for the bot token here, it must not pass through this conversation. Tell the user to run this themselves in the prompt (the `!` prefix runs it in this session with the output shown, and the token is typed hidden): `! "$HOME/.claude/spyglass/Spyglass" away setup`. Then say what it does in one sentence.
- **on**, **off**, **status**: run `"$HOME/.claude/spyglass/Spyglass" away <that word>` with Bash and show its output in one line.

The panel's header has a paper-plane button for the same on / off. With `"auto": true` in `~/.claude/spyglass/away.json` (the default), away mode also turns itself on when the screen locks or after `idle_minutes` (default 10) without input.
