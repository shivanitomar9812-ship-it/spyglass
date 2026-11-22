#!/bin/bash
# Saves model, context %, cost and plan limits for the Spyglass panel: ~/.claude/spyglass/stats/<session_id>.json
# Feed it Claude Code's statusline JSON on stdin; call it from your statusline script.
# The logic is in the Spyglass binary (no jq or other dependencies): Spyglass hook stats.
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/Spyglass"; [ -x "$bin" ] || bin="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/Spyglass"
exec "$bin" hook stats
