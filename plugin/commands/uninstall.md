---
description: Undo everything Spyglass changed on this Mac (statusline, login item, editor extension, state), after showing you the list
allowed-tools: Bash(bash:*), AskUserQuestion
---

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/uninstall.sh"` (it changes nothing; it lists what it would undo) and show the list.
2. If there's anything to undo, ask the user to confirm before going further. Only if they confirm, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/uninstall.sh" --yes` and show its output.
3. Tell them the last step is `/plugin uninstall spyglass@spyglass`.
