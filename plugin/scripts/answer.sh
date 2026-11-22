#!/bin/bash
# PermissionRequest hook: lets the Spyglass panel answer a permission prompt (Allow once / Deny) in any host where hooks
# run - iTerm2, Terminal.app, Cursor / VS Code (terminal or Claude panel), JetBrains, cmux - without typing keys.
#
# Claude Code shows its own prompt while this waits, and the first answer wins: answer in the terminal and this hook's
# answer is ignored; answer in Spyglass and the terminal prompt closes. So this never blocks you.
# It waits only while the panel is running, and exits as soon as the prompt is resolved anywhere.
# No output = no decision (the normal prompt carries on).
# The logic is in the Spyglass binary (no jq or other dependencies): Spyglass hook answer.
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/Spyglass"; [ -x "$bin" ] || bin="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/Spyglass"
exec "$bin" hook answer
