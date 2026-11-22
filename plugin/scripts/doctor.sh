#!/bin/bash
# /spyglass:doctor: checks every link from this session to the panel (the logic is in the Spyglass binary).
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../bin/Spyglass"; [ -x "$bin" ] || bin="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/Spyglass"
exec "$bin" doctor "$here/.." "$@"
