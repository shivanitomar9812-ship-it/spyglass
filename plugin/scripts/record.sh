#!/bin/bash
# Records per-session state for the Spyglass panel: ~/.claude/spyglass/sessions/<session_id>.json
# Runs on every hook event; must stay fast and never fail the session.
# The logic is in the Spyglass binary (no jq or other dependencies): Spyglass hook record.
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/Spyglass"; [ -x "$bin" ] || bin="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/Spyglass"
exec "$bin" hook record
